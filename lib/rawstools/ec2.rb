module RAWSTools
	EC2_Default_Template = <<EOF
  dry_run: ${@dryrun|false}
  image_id: ${@ami|none} # or e.g. $ {@ami|$ {%ami:somedefault}}
  min_count: 1
  max_count: 1
  key_name: ${@key|none}
  #security_group_ids:
  #- (requires override)
  #user_data: (override or omit)
  instance_type: ${@type|none} # or $ {@type|some_default}
  # NOTE: block_device_mappings are intelligently overwritten;
  # if /dev/sda1 is present in the template, it overwrites the
  # one in the template. Otherwise, any additional devs are added
  # to the default definition for /dev/sda1.
  # This definition of /dev/sda1 corrects for AMIs built
  # that incorrectly have delete_on_termination: false
  # block_device_mappings:
  # - device_name: /dev/sda1
  #   ebs:
  #     delete_on_termination: true
  # Uncomment to create data volume for a given template
  #- device_name: /dev/sdf
  #  ebs:
  #    delete_on_termination: false
  #    snapshot_id: ${@snapshot_id|none} # create_instance deletes this if there's no snapshot
  #    volume_size: ${@datasize|5}
  #    volume_type: ${@volume_type|standard} # accepts standard, io1, gp2, sc1, st1
  #    iops: ${@iops|1} # deleted when volume_type != io1
  #    encrypted: ${@encrypted|true}
  monitoring:
    enabled: ${@monitor|false}
  #subnet_id: (requires override)
  instance_initiated_shutdown_behavior: stop
  # Uncomment to use an instance profile with this template
  #iam_instance_profile:
  #  arn: "String"
  ebs_optimized: ${@ebsoptimized|false}
EOF
	class Ec2
		attr_reader :client, :resource

		def initialize(cloudmgr)
			@mgr = cloudmgr
			@client = Aws::EC2::Client.new( region: @mgr["Region"] )
			@resource = Aws::EC2::Resource.new(client: @client)
		end

		def dump_template()
			puts <<EOF
---
tags:
  Foo: Bar # Modify or remove tags entirely
api_template:
#{EC2_Default_Template}
EOF
		end

		# :call-seq:
		#   resolve_instance(name, [states]) -> instance_id|nil, error_msg
		# Resolve an instance name to an instance ID
		def resolve_instance(name=nil, states=nil)
			if name
				name = @mgr.normalize(name)
			else
				name = @mgr.getparam("name")
			end
			states = [ "pending", "running", "shutting-down", "stopping", "stopped" ] unless states
			f = [
				{ name: "tag:Name", values: [ name ] },
				{ name: "tag:Domain", values: [ @mgr["DNSDomain"] ] },
				{
					name: "instance-state-name",
					values: states,
				}
			]
			instances = @resource.instances(filters: f)
			count = instances.count()
			return nil, "Multiple matches for Name: #{instance}" if count > 1
			return nil, "No instance found with Name: #{name} in any of the states: #{states}" if count != 1
			return instances.first(), nil
		end

		def list_instances(states=nil)
			states = [ "pending", "running", "shutting-down", "stopping", "stopped" ] unless states
			f = [
				{ name: "instance-state-name", values: states },
				{ name: "tag:Domain", values: [ @mgr["DNSDomain"] ] },
			]
			instances = @resource.instances(filters: f)
			return instances
		end

		def get_tag(item, tagname)
			item.tags.each() do |tag|
				return tag.value if tag.key == tagname
			end
			return nil
		end

		def resolve_volume(volname=nil, status=[ "available" ], extrafilters=[] )
			if volname
				@mgr.setparam("volname", volname)
				@mgr.normalize_name_parameters()
			end
			volname = @mgr.getparam("volname")
			f = [
				{ name: "tag:Name", values: [ volname ] },
				{ name: "tag:Domain", values: [ @mgr["DNSDomain"] ] },
				{ name: "status", values: status }
			]
			f += extrafilters
			v = @resource.volumes(filters: f)
			count = v.count()
			return nil, "Multiple matches for volume: #{volname}" if count > 1
			return nil, "No volume found with Name: #{volname} and Status: #{status}" if count != 1
			return v.first(), nil
		end

		def get_instance_data_volume(i)
			bd = i.block_device_mappings()
			rd = i.root_device_name
			name = get_tag(i, "Name")
			bd.each() do |b|
				next if b.device_name == rd
				v = @resource.volume(b.ebs.volume_id)
				if get_tag(v, "Name") == name
					return v, nil
				end
			end
			return nil, "Couldn't locate an attached volume with Name: #{name}"
		end

		def get_data_volume(name=nil)
			if name
				name = @mgr.normalize(name)
			else
				name = @mgr.getparam("name")
			end
			i, err = resolve_instance()
			return nil, "#{err}" unless i
			return get_instance_data_volume(i)
		end

		def get_instance_root_volume(i)
			rd = i.root_device_name
			i.block_device_mappings.each() do |b|
				return @resource.volume(b.ebs.volume_id), nil if b.device_name == rd
			end
		end

		def get_root_volume(name=nil)
			if name
				name = @mgr.normalize(name)
			else
				name = @mgr.getparam("name")
			end
			i, err = resolve_instance()
			return nil, "#{err}" unless i
			return get_instance_root_volume(i)
		end

		def delete_volume(volname=nil, wait=true)
			if volname
				@mgr.setparam("volname", volname)
				@mgr.normalize_name_parameters()
			end
			volname = @mgr.getparam("volname")
			volume, err = resolve_volume()
			if volume
				yield "#{@mgr.timestamp()} Deleting volume: #{volname}"
				volume.delete()
				return true unless wait
				yield "#{@mgr.timestamp()} Waiting for volume to finish deleting..."
				@client.wait_until(:volume_deleted, volume_ids: [ volume.id() ])
				yield "#{@mgr.timestamp()} Deleted"
				return true
			else
				yield "#{@mgr.timestamp()} #{err}"
				return false
			end
		end

		def list_volumes()
			f = [
				{ name: "tag:Domain", values: [ @mgr["DNSDomain"] ] },
			]
			volumes = @resource.volumes(filters: f)
			return volumes
		end

		def resolve_snapshot(snapid)
			f = [
				{ name: "snapshot-id", values: [ snapid ] },
				{ name: "tag:Domain", values: [ @mgr["DNSDomain"] ] },
			]
			s = @resource.snapshots(filters: f)
			count = s.count()
			return nil, "No snapshot found for domain #{@mgr["DNSDomain"]} with id: #{snapid}" if count != 1
			return s.first(), nil
		end

		def delete_snapshot(snapid)
			s, err = resolve_snapshot(snapid)
			if s
				yield "#{@mgr.timestamp()} Deleting snapshot #{snapid}"
				s.delete()
				return true
			else
				yield "#{@mgr.timestamp()} Couldn't resolve snapshot #{snapid}: #{err}"
				return false
			end
		end

		def list_snapshots(name=nil, type=nil)
			f = [
				{ name: "tag:Domain", values: [ @mgr["DNSDomain"] ] },
			]
			if name
				name = @mgr.normalize(name)
				f << { name: "tag:Name", values: [ name ] }
			end
			if type
				f << { name: "tag:SnapshotType", values: [ type ] }
			end
			snapshots = @resource.snapshots(filters: f)
			return snapshots
		end

		def create_snapshot(volname=nil, wait=false, type="manual")
			if volname
				@mgr.setparam("volname", volname)
				@mgr.normalize_name_parameters()
			end
			volname = @mgr.getparam("volname")

			# Look for unattached volume first
			vol, err = resolve_volume(nil, [ "available" ])
			# Or an in-use non-root volume
			unless vol
				vol, err = resolve_volume(nil, [ "in-use" ],
				[ { name: "attachment.device", values: [ "/dev/sdf", "/dev/xvdf" ] } ] )
			end
			unless vol
				yield "#{@mgr.timestamp()} #{err}"
				return nil
			end
			yield "#{@mgr.timestamp()} Creating snapshot for volume #{volname}"
			snap = vol.create_snapshot()
			tags = vol.tags
			snaptags = []
			tags.each() do |tag|
				if not tag.key.start_with?("aws:")
					snaptags << { key: tag.key, value: tag.value }
				end
			end
			snaptags << { key: "SnapshotType", value: type }
			yield "#{@mgr.timestamp()} Tagging snapshot"
			snap.create_tags(tags: snaptags)
			return snap unless wait
			yield "#{@mgr.timestamp()} Waiting for snapshot to complete"
			snap.wait_until_completed()
			yield "#{@mgr.timestamp()} Completed"
			return snap
		end

		def create_volume(size, wait=true)
			# TODO: Implement
		end

		def attach_volume()
			# TODO: Implement
		end

		def list_types()
			Dir::chdir("ec2") do
				Dir::glob("*.yaml").map() { |t| t[0,t.index(".yaml")] }
			end
		end

		def get_metadata(template)
			templatefile = nil
			if template.end_with?(".yaml")
				templatefile = template
			else
				templatefile = "ec2/#{template}.yaml"
			end
			begin
				raw = File::read(templatefile)
				data = YAML::load(raw)
				return data["metadata"], nil if data["metadata"]
				return nil, "No metadata found for #{template}"
			rescue
				return nil, "Error reading template file #{templatefile}"
			end
		end

		# :call-seq:
		#   create_instance(name, key, template, wait) -> Aws::EC2::Instance|nil, msg
		#
		# If instance is nil, msg contains the error, otherwise msg is informative
		def create_instance(name, key, template, wait=true)
			if name
				@mgr.normalize(name)
			end
			@mgr.setparam("key", key)
			name, volname, snapid, datasize, availability_zone, dryrun, nodns = @mgr.getparams("name", "volname", "snapid", "datasize", "availability_zone", "dryrun", "nodns")

			i, err = resolve_instance()
			if i
				msg = "Instance #{name} already exists"
				yield "#{@mgr.timestamp()} #{msg}"
				return nil, msg
			end

			rr = @mgr.route53.lookup(@mgr["PrivateDNSId"])
			if rr.size != 0
				msg = "DNS record for #{name} already exists"
				yield "#{@mgr.timestamp()} #{msg}"
				return nil
			end

			templatefile = nil
			if template.end_with?(".yaml")
				templatefile = template
			else
				templatefile = "ec2/#{template}.yaml"
			end
			begin
				raw = File::read(templatefile)
			rescue => e
				msg = "Error in File::Read for template file #{templatefile}: #{e.message}"
				yield "#{@mgr.timestamp()} #{msg}"
				return nil, msg
			end

			if volname and ( snapid or datasize )
				msg = "Invalid parameters: volume provided with snapshot and/or data size"
				yield "#{@mgr.timestamp()} #{msg}"
				return nil, msg
			end

			if dryrun == "true" or dryrun == true
				dry_run = true
			else
				dry_run = false
			end

			if volname
				yield "#{@mgr.timestamp()} Looking up volume: #{volname}"
				volume, err = resolve_volume()
				unless volume
					msg = "Error looking up given volume: #{err}"
					yield "#{@mgr.timestamp()} #{msg}"
					return nil, msg
				end
			end
			existing, err = resolve_volume(name)
			if existing
				if volume
					msg = "Launching with volume #{volname} will create a duplicate volume name for existing volume #{name}; delete existing volume or use attach volume instead"
					yield "#{@mgr.timestamp()} #{msg}"
					return nil, msg
				else
					volume = existing
					yield "#{@mgr.timestamp()} Found existing volume for #{name}: #{volume.id()}"
				end
			end

			if volume
				vol_az = volume.availability_zone()
				if availability_zone and availability_zone != vol_az
					yield "#{@mgr.timestamp()} Overriding provided availability zone: #{availability_zone} with zone from volume: #{volname}: #{vol_az}"
				end
				az = vol_az[-1].upcase()
				@mgr.setparam("az", az)
				@mgr.setparam("availability_zone", vol_az)
			else
				az = @mgr["AvailabilityZones"].sample().upcase()
				availability_zone = @mgr["Region"] + az.downcase()
				yield "#{@mgr.timestamp()} Picked random availability zone: #{availability_zone}"
				@mgr.setparam("az", az)
				@mgr.setparam("availability_zone", availability_zone)
			end

			raw = @mgr.expand_strings(raw)
			template = YAML::load(raw)
			@mgr.resolve_vars( { "child" => template }, "child" )
			@mgr.symbol_keys(template)

			# Load the default template
			apibase = @mgr.expand_strings(EC2_Default_Template)
			ispec = YAML::load(apibase)
			@mgr.resolve_vars( { "child" => ispec }, "child" )
			@mgr.symbol_keys(ispec)

			ispec = ispec.merge(template[:api_template])

			if ispec[:user_data]
				ispec[:user_data] = Base64::encode64(ispec[:user_data])
			end

			if ispec[:block_device_mappings]
				ispec[:block_device_mappings].delete_if() do |dev|
					if dev[:device_name].end_with?("a")
						false
					elsif dev[:device_name].end_with?("a1")
						false
					elsif volume
						true
					else
						e=dev[:ebs]
						if snapid
							e.delete(:encrypted)
							snapshot, err = resolve_snapshot(snapid)
							unless snapshot
								yield "#{@mgr.timestamp()} Error resolving snapshot: #{snapid}"
								return nil
							end
							sname = get_tag(snapshot, "Name")
							stime = snapshot.start_time.getlocal.strftime("%F|%R")
							yield "#{@mgr.timestamp()} Launching with data volume from snapshot #{snapshot.id()} for #{sname} created: #{stime}"
							e[:snapshot_id] = snapshot.id()
						else
							e.delete(:snapshot_id)
						end
						e.delete(:iops) unless e[:volume_type] == "io1"
						false
					end
				end
			end
			if ispec[:block_device_mappings] && ispec[:block_device_mappings].size == 0
				ispec.delete(:block_device_mappings)
			end
			yield "#{@mgr.timestamp()} Dry run, creating: #{ispec}" if dry_run

			interfaces = []
			if template[:additional_interfaces]
				template[:additional_interfaces].each() do |iface|
					interfaces << @resource.create_network_interface(iface)
				end
			end
			@mgr.normalize_name_parameters()
			cfgtags = @mgr.tags
			name = @mgr.getparam("name")
			cfgtags["Name"] = name
			cfgtags["Domain"] = @mgr["DNSDomain"]
			cfgtags.add(template[:tags]) if template[:tags]
			itags = cfgtags.apitags()
			cfgtags["InstanceName"] = @mgr.getparam("name")
			vtags = cfgtags.apitags()
			ispec[:tag_specifications] = [
				{
					resource_type: "instance",
					tags: itags,
				},
				{
					resource_type: "volume",
					tags: vtags,
				}
			]
			# puts "Creating: #{ispec}"

			begin
				instances = @resource.create_instances(ispec)
			rescue => e
				msg = "Caught exception creating instance: #{e.message}"
				yield "#{@mgr.timestamp()} #{msg}"
				abort_instance(nil, interfaces, wait, false)
				return nil, msg
			end
			instance = nil
			unless dry_run
				instance = instances.first()
				yield "#{@mgr.timestamp()} Created instance #{name} (id: #{instance.id()}), waiting for it to enter state running ..."
				instance.wait_until_running()
				yield "#{@mgr.timestamp()} Running"
				if interfaces.size > 0
					iface_index = 1
					interfaces.each() do |iface|
						yield "#{@mgr.timestamp()} Attaching additional interface ##{iface_index} to #{instance.id()}"
						attach = iface.attach({ instance_id: instance.id(), device_index: iface_index })
						iface.modify_attribute({ attachment: { attachment_id: attach.attachment_id, delete_on_termination: true } })
						iface_index += 1
					end
				end

				msg = nil
				if volume
					if volume.state == "available"
						msg = "Used existing volume"
						yield "#{@mgr.timestamp()} Attaching data volume: #{volume.id()}"
						begin
							instance.attach_volume({
								volume_id: volume.id(),
								device: "/dev/sdf",
							})
						rescue => e
							msg = "Unable to attach volume, aborting"
							yield "#{@mgr.timestamp()} #{msg}"
							abort_instance(instance, [], wait, true) { |s| yield s }
							return nil, msg
						end
						@client.wait_until(:volume_in_use, volume_ids: [ volume.id() ])
					else
						msg = "Data volume not in state 'available', aborting"
						yield "#{@mgr.timestamp()} #{msg}"
						abort_instance(instance, [], wait, true) { |s| yield s }
						return nil, msg
					end
				end

				# Need to refresh to get attached volumes
				instance = @resource.instance(instance.id())

				# Acquire global lock during tagging and dns updates to insure
				# unique instance names and unused DNS records.
				@mgr.lock() # NOTE: unlock() will be called by either abort_instance or update_dns
				# Make sure this is the only instance with this Name
				i, err = resolve_instance()
				if err
					# We haven't applied tags yet, but we found an instance with the same
					# name
					msg = "Instance with same name \"#{name}\" created during launch, aborting"
					yield "#{@mgr.timestamp()} #{msg}"
					abort_instance(instance, [], wait, true) { |s| yield s }
					return nil, msg
				end

				instance = @resource.instance(instance.id())
				rr = @mgr.route53.lookup(@mgr["PrivateDNSId"])
				if rr.size != 0
					msg = "DNS record for #{name} created during launch"
					yield "#{@mgr.timestamp()} #{msg}"
					abort_instance(instance, [], wait, true) { |s| yield s }
					return nil, msg
				end

				update_dns(nil, wait, instance, true) { |s| yield s }
				# @mgr.unlock() - called by update_dns as soon as records are added
				return instance, msg
			else
				return nil, nil
			end
		end

		# Abort creation because of errors detected post create_instances
		def abort_instance(instance, interfaces, wait, unlock=false)
			@mgr.unlock() if unlock
			if interfaces.size > 0
				interfaces.each() do |iface|
					iface.delete()
				end
			end
			return unless instance
			yield "#{@mgr.timestamp()} Aborting instance #{instance.id()}"
			instance.block_device_mappings().each() do |b|
				v = @resource.volume(b.ebs.volume_id)
				# Volumes without a Name should be deleted. Note that if an
				# instance is aborted after tagging, the volume will get left
				# behind. This should be extremely rare, since the most likely
				# collision is two people creating an instance with the same
				# name at the same time.
				unless get_tag(v, "Name")
					yield "#{@mgr.timestamp()} Marking new unnamed volume #{b.ebs.volume_id} (#{b.device_name}) for automatic deletion"
					instance.modify_attribute({
						attribute: "blockDeviceMapping",
						block_device_mappings: [
					    {
					      device_name: b.device_name,
					      ebs: {
					        volume_id: b.ebs.volume_id,
					        delete_on_termination: true,
					      },
					    },
					  ],
					})
				end
			end
			yield "#{@mgr.timestamp()} Sending termination command"
			instance.terminate()
			return unless wait
			yield "#{@mgr.timestamp()} Waiting for instance to terminate..."
			instance.wait_until_terminated()
			yield "#{@mgr.timestamp()} Terminated"
		end

		def reboot_instance(name=nil)
			if name
				name = @mgr.normalize(name)
			else
				name = @mgr.getparam("name")
			end
			instance, err = resolve_instance(nil, [ "running" ])
			if instance
				yield "#{@mgr.timestamp()} Rebooting #{name}"
				instance.reboot()
				return instance
			else
				yield "#{@mgr.timestamp()} Error resolving #{name}: #{err}"
				return nil
			end
		end

		def start_instance(name=nil, wait=true)
			if name
				name = @mgr.normalize(name)
			else
				name = @mgr.getparam("name")
			end
			instance, err = resolve_instance(nil, [ "stopped" ])
			if instance
				@mgr.setparam("volname", name)
				volume, err = resolve_volume()
				if volume
					if volume.availability_zone() != @resource.subnet(instance.subnet_id()).availability_zone()
						yield "#{@mgr.timestamp()} Found existing volume in wrong availability zone, ignoring"
						volume = nil
					else
						yield "#{@mgr.timestamp()} Attaching existing data volume: #{name}"
						instance.attach_volume({
							volume_id: volume.id(),
							device: "/dev/sdf",
						})
						@client.wait_until(:volume_in_use, volume_ids: [ volume.id() ])
					end
				end
				yield "#{@mgr.timestamp()} Starting #{name}"
				instance.start()
				yield "#{@mgr.timestamp()} Started instance #{name} (id: #{instance.id()}), waiting for it to enter state running ..."
				instance.wait_until_running()
				yield "#{@mgr.timestamp()} Running"
				# Need to refresh
				instance = @resource.instance(instance.id())

				update_dns(nil, wait, instance) { |s| yield s }
			else
				yield "#{@mgr.timestamp()} Error resolving #{name}: #{err}"
				return nil
			end
		end

		def stop_instance(name=nil, wait=true)
			if name
				@mgr.normalize(name)
			end
			instance, err = resolve_instance(nil, [ "running" ])
			name, detach = @mgr.getparams("name", "detach")
			if instance
				yield "#{@mgr.timestamp()} Stopping #{name}"
				instance.stop()
				remove_dns(instance) { |s| yield s }
				return unless wait or detach
				yield "#{@mgr.timestamp()} Waiting for instance to stop..."
				instance.wait_until_stopped()
				yield "#{@mgr.timestamp()} Stopped"
				if detach
					detach_volume() { |s| yield s }
				end
			else
				yield "#{@mgr.timestamp()} Error resolving #{name}: #{err}"
			end
		end

		def detach_instance_volume(instance, volname=nil)
			name = @mgr.getparam("name")
			unless volname
				volume, err = get_instance_data_volume(instance)
				unless volume
					yield "#{@mgr.timestamp()} Couldn't find data volume for #{name}: #{err}"
					return nil
				end
			else
				volume, err = resolve_volume(volname, [ "in-use" ],
				[ { name: "attachment.device", values: [ "/dev/sdf", "/dev/xvdf" ] } ] )
				unless volume
					yield "#{@mgr.timestamp} Unable to resolve volume #{volname}"
					return nil
				end
			end
			device = nil
			volume.attachments().each() do |att|
				if att.instance_id == instance.id
					device = att.device
				end
			end
			unless device
				yield "#{@mgr.timestamp()} Volume not attached"
				return nil
			end
			yield "#{@mgr.timestamp()} Detaching volume #{volume.id} from instance #{instance.id}"
			return volume.detach_from_instance({
				instance_id: instance.id,
				device: device,
			})
		end

		# Detach data volume from an instance
		def detach_volume(name=nil, volname=nil)
			if name
				@mgr.setparam("name", name)
			end
			if volname
				@mgr.setparam("volname", volname)
			end
			@mgr.normalize_name_parameters()
			name, volname = @mgr.getparams("name", "volname")
			instance, err = resolve_instance()
			unless instance
				yield "#{@mgr.timestamp()} detach_volume called on non-existing instance #{name}: #{err}"
			  return nil
			end
			return detach_instance_volume(instance, volname) { |s| yield s }
		end

		def terminate_instance(name=nil, wait=true, deletevol=false)
			if name
				name = @mgr.normalize(name)
			else
				name = @mgr.getparam("name")
			end
			instance, err = resolve_instance()
			if instance
				yield "#{@mgr.timestamp()} Terminating #{name}"
				remove_dns = false
				remove_dns = true if instance.state.name == "running"
				instance.terminate()
				remove_dns(instance, wait) { |s| yield s } if remove_dns
				return unless wait or deletevol
				yield "#{@mgr.timestamp()} Waiting for instance to terminate..."
				instance.wait_until_terminated()
				yield "#{@mgr.timestamp()} Terminated"
				if deletevol
					@mgr.setparam("volname", name)
					volume,err = resolve_volume(nil, [ "available", "in-use" ])
					if volume
						yield "#{@mgr.timestamp()} Waiting for volume to be available..."
						@client.wait_until(:volume_available, {
							volume_ids: [ volume.id() ]
						})
						yield "#{@mgr.timestamp()} Deleting volume #{name}, id: #{volume.id()}"
						delete_volume(nil, wait) { |s| yield s }
					else
						yield "#{@mgr.timestamp()} Not deleting data volume: #{err}"
					end
				end
			else
				yield "#{@mgr.timestamp()} Error resolving #{name}: #{err}"
				return false
			end
			return true
		end

		def remove_dns(instance, wait=false)
			fqdn = @mgr.getparam("fqdn")
			pub_ip = instance.public_ip_address
			priv_ip = instance.private_ip_address

			pubzone = @mgr["PublicDNSId"]
			privzone = @mgr["PrivateDNSId"]

			change_ids = []
			if pub_ip and pubzone
				yield "#{@mgr.timestamp()} Removing public DNS record #{fqdn} -> #{pub_ip}"
				change_ids << @mgr.route53.delete(pubzone)
			end
			if priv_ip and privzone
				yield "#{@mgr.timestamp()} Removing private DNS record #{fqdn} -> #{priv_ip}"
				change_ids << @mgr.route53.delete(privzone)
			end
			return unless wait
			yield "#{@mgr.timestamp()} Waiting for zones to synchronize..."
			change_ids.each() { |id| @mgr.route53.wait_sync(id) }
			yield "#{@mgr.timestamp()} Synchronized"
		end

		def update_dns(name=nil, wait=false, instance=nil, unlock=false)
			if name
				name = @mgr.normalize(name)
			else
				name = @mgr.getparam("name")
			end
			instance, err = resolve_instance(nil, [ "running" ]) unless instance

			name = @mgr.getparam("name")
			unless instance
				yield "#{@mgr.timestamp()} Update_dns called on non-existing instance #{name}: #{err}"
				return false
			end

			pub_ip = instance.public_ip_address
			priv_ip = instance.private_ip_address

			pubzone = @mgr["PublicDNSId"]
			privzone = @mgr["PrivateDNSId"]

			change_ids = []
			if pub_ip and pubzone
				@mgr.setparam("zone_id", pubzone)
				@mgr.setparam("ipaddr", pub_ip)
				yield "#{@mgr.timestamp()} Adding public DNS record #{name} -> #{pub_ip}"
				change_ids << @mgr.route53.change_records("arec")
			end
			if priv_ip and privzone
				@mgr.setparam("zone_id", privzone)
				@mgr.setparam("ipaddr", priv_ip)
				yield "#{@mgr.timestamp()} Adding private DNS record #{name} -> #{priv_ip}"
				change_ids << @mgr.route53.change_records("arec")
			end
			# Don't hold the global lock while waiting for zones to synchronize
			@mgr.unlock() if unlock
			return true unless wait
			yield "#{@mgr.timestamp()} Waiting for zones to synchronize..."
			change_ids.each() { |id| @mgr.route53.wait_sync(id) }
			yield "#{@mgr.timestamp()} Synchronized"
			return true
		end
	end
end
