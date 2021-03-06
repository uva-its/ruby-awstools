require 'base64'
require 'yaml'
require 'json'
require 'fileutils'
require 'pathname'
require 'aws-sdk-ec2'
require 'aws-sdk-iam'
require 'aws-sdk-rds'
require 'aws-sdk-route53'
require 'aws-sdk-s3'
require 'aws-sdk-simpledb'
require 'aws-sdk-cloudformation'
require 'rawstools/cloudformation'
require 'rawstools/ec2'
require 'rawstools/rds'
require 'rawstools/route53'
require 'rawstools/simpledb'

module RAWSTools

  # An api_template (for rds especially) defines a host of api keys that
  # may or may not be needed for a given operation. prune_template takes
  # a list of keys appropriate to an operation and prunes extra keys from
  # the template. Callers should take care to dup() the original if Multiple
  # calls need to be made. See e.g. rds create w/ Aurora
  def prune_template(template, keys)
    template.keys.each do |key|
      unless keys.include?(key)
        template.delete(key)
      end
    end
  end

  Valid_Classes = [ "String", "Fixnum", "Integer", "TrueClass", "FalseClass" ]
  Expand_Regex = /\${([@=%&~][:|.\-\/\w<>=#]+)}/
  Log_Levels = [:trace, :debug, :info, :warn, :error]

  # Class to convert from configuration file format to AWS expected format
  # for tags
  class Tags
    attr_reader :tags

    def initialize(cfg)
      @tags = Marshal.load(Marshal.dump(cfg["Tags"])) if cfg["Tags"]
      @tags ||= {}
    end

    # Tags for API calls
    def apitags()
      tags = []
      @tags.each_key do |k|
        tags.push({ :key => k, :value => @tags[k] })
      end
      return tags
    end

    # Cloudformation template tags
    def cfntags()
      tags = []
      @tags.each_key do |k|
        tags.push({ "Key" => k, "Value" => @tags[k] })
      end
      return tags
    end

    def []=(key, value)
      @tags[key] = value
    end

    def add(tags)
      if tags.class().to_s() == "Hash"
        hash = tags
      else
        hash = {}
        tags.each do |tag|
          hash[tag["Key"]] = tag["Value"]
        end
      end
      @tags = @tags.merge(hash)
    end
  end

  # Central library class that loads the configuration file and provides
  # utility classes for processing names and templates.
  class CloudManager
    attr_reader :installdir, :subdom, :cfn, :sdb, :s3, :s3res, :ec2, :rds, :region, :route53, :tags, :params, :stack_family, :govcloud, :client_opts

    # Initiallize
    def initialize(paramhash, logarray = nil, loglevel = nil)
      @installdir = File.dirname(Pathname.new(__FILE__).realpath) + "/rawstools"
      @logarray = logarray if logarray
      log_set = false
      if ENV["RAWS_LOGLEVEL"] || loglevel
        unless loglevel
          ll = ENV["RAWS_LOGLEVEL"].to_sym()
          ll = :info unless Log_Levels.include?(ll)
        else
          ll = loglevel
        end
        if Log_Levels.index(ll) != nil
          @loglevel = Log_Levels.index(ll)
          log_set = true
        end
      else
        @loglevel = Log_Levels.index(:info)
      end
      begin
        @file = File::open("cloudconfig.yaml")
      rescue => e
        $stderr.puts("Error reading cloudconfig.yaml: #{e.message}")
        exit(1)
      end
      raw = @file.read()
      # A number of config items need to be defined before using expand_strings
      @config = YAML::load(raw)
      # For SearchPath items that expand an environment variable
      resolve_vars(@config, "SearchPath")
      search_dirs = ["#{@installdir}/templates"]
      if @config["SearchPath"]
        search_dirs += @config["SearchPath"]
      end
      search_dirs += ["."]

      @params = {}
      @params = @params.merge(paramhash)
      @config = {}
      repositories = []
      search_dirs.each do |dir|
        log(:debug, "Looking for #{dir}/cloudconfig.yaml")
        if File::exist?("#{dir}/cloudconfig.yaml")
          log(:info, "Loading configuration and variables from #{dir}/cloudconfig.yaml")
          raw = File::read("#{dir}/cloudconfig.yaml")
          merge_templates(YAML::load(raw), @config)
        end
        Dir::chdir(dir) do
          reponame = File.basename(`git rev-parse --show-toplevel`).chomp()
          repohash = `git rev-parse --short=8 HEAD`.chomp()
          dirtyflag = `git diff --quiet --ignore-submodules HEAD 2>/dev/null; [ $? -eq 1 ] && echo "+"`.chomp()
          repository = "#{reponame}@#{repohash}#{dirtyflag}"
          repositories << repository unless repositories.include?(repository)
        end
      end
      @params["repositories"] = repositories.join(":")
      @params["creator"] = ENV["USER"] unless @params["creator"]

      if @config["LogLevel"] && ! log_set
        ll = @config["LogLevel"].to_sym()
        if Log_Levels.index(ll) != nil
          @loglevel = Log_Levels.index(ll)
        end
      end

      @client_opts = {}
      if @config["Region"]
        @region = @config["Region"]
        @client_opts = { region: @region }
      end

      @sts = Aws::STS::Client.new( @client_opts )
      info = @sts.get_caller_identity()
      if info.account.to_s != @config["AccountID"].to_s
        raise "AccountID for credentials (#{info.account}) don't match configured AccountID (#{@config["AccountID"]}), the current site repository is configured for a different AWS account."
      end
      @govcloud = false
      if info.arn.start_with?("arn:aws-us-gov")
        @govcloud = true
      end
      @subdom = nil
      @ec2 = Ec2.new(self)
      @cfn = CloudFormation.new(self)
      @iam = Aws::IAM::Client.new( @client_opts )
      @iamres = Aws::IAM::Resource.new( client: @iam )
      @sdb = SimpleDB.new(self)
      @s3 = Aws::S3::Client.new( @client_opts )
      @s3res = Aws::S3::Resource.new( client: @s3 )
      @rds = RDS.new(self)
      @route53 = Route53.new(self)
      @stack_family = ""
      if @config["StackFamily"] != nil
        @stack_family = expand_strings(@config["StackFamily"])
        unless @stack_family.end_with?("-")
          @stack_family += "-"
        end
      end

      [ "DNSBase", "DNSDomain" ].each do |c|
        if ! @config[c]
          raise "Missing required top-level configuration item in #{@filename}: #{c}"
        end
      end

      [ "DNSBase", "DNSDomain" ].each do |dnsdom|
        name = @config[dnsdom]
        if name.end_with?(".")
          STDERR.puts("Warning: removing trailing dot from #{dnsdom}")
          @config[dnsdom] = name[0..-2]
        end
        if name.start_with?(".")
          STDERR.puts("Warning: removing leading dot from #{dnsdom}")
          @config[dnsdom] = name[1..-1]
        end
      end
      raise "Invalid configuration, DNSDomain same as or subdomain of DNSBase" unless @config["DNSDomain"].end_with?(@config["DNSBase"])
      if @config["DNSDomain"] != @config["DNSBase"]
        i = @config["DNSDomain"].index(@config["DNSBase"])
        @subdom = @config["DNSDomain"][0..(i-2)]
      end
      # Generate userparameters hash
      normalize_name_parameters()
      parr = []
      paramhash.each_key do |k,v|
        parr << "#{k}=#{@params[k]}"
      end
      @params["userparameters"] = parr.join("+") if parr.size > 0
      # Resolve tags after generated parameters are done, so tags can reference
      # all parameters including generated ones.
      resolve_vars(self, "Tags")
      @tags = Tags.new(self)
    end

    # Log events, takes a symbol log level (see Log_Levels) and a message.
    # NOTE: eventually there should be a separate configurable log level for
    # stuff that also gets logged to CloudWatch logs and/or syslog.
    def log(level, message)
      ll = Log_Levels.index(level)
      if ll != nil && ll >= @loglevel
        if @logarray
          @logarray.push(message)
        else
          $stderr.puts("#{level.to_s}: #{message}")
        end
      end
    end

    # Implement a simple mutex to prevent collisions. Scripts can use a lock
    # to synchronize updates to the repository.
    def lock()
      @file.flock(File::LOCK_EX)
    end

    def unlock()
      @file.flock(File::LOCK_UN)
    end

    def timestamp()
      now = Time.new()
      return now.strftime("%Y%m%d%H%M")
    end

    def normalize_name_parameters()
      domain = @config["DNSDomain"]
      base = @config["DNSBase"]
      # NOTE: skipping 'snapname' for now, since they will likely
      # be of the form <name>-<timestamp>
      ["name", "cname", "volname"].each() do |name|
        norm = getparam(name)
        next unless norm
        log(:trace,"Normalizing #{norm}")
        norm = norm.gsub(/\.+/, '.')
        # fqdn with dot given
        if norm.end_with?(".#{domain}.")
          fqdn = norm
          i = norm.index(base)
          norm = norm[0..(i-2)]
        # fqdn w/o dot given
        elsif norm.end_with?(".#{domain}")
          fqdn = norm + "."
          i = norm.index(base)
          norm = norm[0..(i-2)]
        # shortname with subdom and dot
        elsif @subdom and norm.end_with?(".#{@subdom}.")
          fqdn = norm + base
          norm = norm[0..-2]
        # shortname with subdom only
        elsif @subdom and norm.end_with?(".#{@subdom}")
          fqdn = norm + "." + base + "."
        # bare name, @subdom set
        elsif @subdom
          norm = norm[0..-2] if norm.end_with?(".")
          fqdn = norm + "." + domain + "."
          norm = norm + "." + @subdom
        # bare name, no @subdom
        else
          norm = norm[0..-2] if norm.end_with?(".")
          fqdn = norm + "." + domain + "."
        end
        log(:trace,"Normalized to #{norm}")
        setparam(name, norm)
        case name
        when "name"
          setparam("fqdn", fqdn)
          dbname = norm.gsub(".","-")
          setparam("dbname", dbname)
          ansible_name = norm.gsub(/[.-]/, "_")
          setparam("ansible_name", ansible_name)
        when "cname"
          setparam("cfqdn", fqdn)
        end
      end
    end

    # Convience method for quickly normalizing a name
    def normalize(name, param="name")
      @params[param] = name
      normalize_name_parameters()
      return @params[param]
    end

    def setparam(param, value)
      @params[param] = value
    end

    def getparam(param)
      return @params[param]
    end

    def getparams(*p)
      r = []
      p.each() { |k| r << @params[k] }
      return r
    end

    def [](key)
      return nil if @config[key] == nil
      if @config[key].class().to_s == "String"
        return expand_strings(@config[key])
      else
        resolve_vars(@config, key) unless key == "Tags"
        return @config[key]
      end
    end

    # Iterate through a data structure and replace all hash string keys
    # with symbols. Ruby AWS API calls all take symbols as their hash keys.
    # Updates the data structure in-place.
    def symbol_keys(item)
      case item.class().to_s()
      when "Hash"
        item.keys().each() do |key|
          if key.class.to_s() == "String"
            oldkey = key
            key = key.to_sym()
            item[key] = item[oldkey]
            item.delete(oldkey)
          end
          symbol_keys(item[key])
        end
      when "Array"
        item.each() { |i| symbol_keys(i) }
      end
    end

    # merge 2nd-level hashes, src overwrites and modifies dst in place
    def merge_templates(src, dst)
      src.keys.each() do |key|
        if ! dst.has_key?(key)
          dst[key] = src[key]
        else
          if dst[key].class.to_s() == "Hash"
            dst[key] = dst[key].merge(src[key])
          else
            dst[key] = src[key]
          end
        end
      end
    end

    # Load API template files in order from least to most specific; throws an
    # exeption if no specific template with the named type is loaded.
    def load_template(facility, type)
      search_dirs = ["#{@installdir}/templates"]
      search_dirs += @config["SearchPath"] if @config["SearchPath"]
      search_dirs += ["."]
      template = {}
      found = false
      search_dirs.each do |dir|
        log(:debug, "Looking for #{dir}/#{facility}/#{facility}.yaml")
        if File::exist?("#{dir}/#{facility}/#{facility}.yaml")
          log(:info, "Loading api template #{dir}/#{facility}/#{facility}.yaml")
          raw = File::read("#{dir}/#{facility}/#{facility}.yaml")
          merge_templates(YAML::load(raw), template)
        end
        log(:debug, "Looking for #{dir}/#{facility}/#{type}.yaml")
        if File::exist?("#{dir}/#{facility}/#{type}.yaml")
          log(:info, "Loading api template #{dir}/#{facility}/#{type}.yaml")
          found = true
          raw = File::read("#{dir}/#{facility}/#{type}.yaml")
          merge_templates(YAML::load(raw), template)
        end
      end
      unless found
        raise "Couldn't find a #{facility} template for #{type}"
      end
      return template
    end

    # List all the templates available in the SearchPath. Return an array
    # of strings.
    def list_templates(facility, exclude_builtins = true)
      templates = []
      search_dirs = []
      unless exclude_builtins
        search_dirs = ["#{@installdir}/templates"]
      end
      search_dirs += @config["SearchPath"] if @config["SearchPath"]
      search_dirs += ["."]
      search_dirs.each do |dir|
        log(:debug, "Checking for template directory #{dir}")
        if File::directory?("#{dir}/#{facility}")
          Dir::chdir("#{dir}/#{facility}") do
            Dir::glob("*.yaml").each do |t|
              tname = t[0,t.index(".yaml")]
              templates.push(tname) unless tname == facility
            end
          end
        end
      end
      return templates
    end

    # Take a string of the form ${something} and expand the value from
    # config, sdb, parameters, or cloudformation.
    def expand_string(var)
      var = $1 if var.match(Expand_Regex)
      case var[0]
      # passed-in parameters
      when "@"
        param, default = var.split('|')
        if not default and var.end_with?('|')
          default=""
        end
        param = param[1..-1]
        value = getparam(param)
        if value
          return value
        elsif default
          return default
        else
          raise "Reference to undefined parameter: \"#{param}\""
        end
      # environment variables
      when "~"
        env_var, default = var.split('|')
        if not default and var.end_with?('|')
          default=""
        end
        env_var = env_var[1..-1]
        value = ENV[env_var]
        if value
          return value
        elsif default
          return default
        else
          raise "Reference to unset environment variable: \"#{env_var}\""
        end
      # cloudformation resources
      when "="
        lookup, default = var.split('|')
        if not default and var.end_with?('|')
          default=""
        end
        output = lookup[1..-1]
        value = @cfn.getresource(output)
        if value
          return value
        elsif default
          return default
        else
          raise "Output not found while expanding \"#{var}\""
        end
      # simpledb lookups
      when "%"
        lookup, default = var.split('|')
        if not default and var.end_with?('|')
          default=""
        end
        lookup = lookup[1..-1]
        item, key = lookup.split(":")
        raise "Invalid SimpleDB lookup: #{lookup}" unless key
        values = @sdb.retrieve(item, key)
        if values.length == 1
          value = values[0]
          return value
        elsif values.length == 0 and default
          return default
        else
          raise "Failed to receive single-value retrieving attribute \"#{key}\" from item #{item} in SimpleDB domain #{@sdb.getdomain()}, got: #{values}"
        end
      when "&"
        cfgvar, default = var.split('|')
        if not default and var.end_with?('|')
          default=""
        end
        cfgvar = cfgvar[1..-1]
        value = @config[cfgvar]
        if value != nil
          varclass = @config[cfgvar].class().to_s()
          unless Valid_Classes.include?(varclass)
            raise "Bad variable reference during string expansion: \"#{cfgvar}\" expands to non-scalar class #{varclass}"
          end
          return @config[cfgvar]
        elsif default
          return default
        else
          raise "Configuration variable \"#{cfgvar}\" not found in cloudconfig.yaml locally or in the SearchPath"
        end
      end
    end

    # Iteratively expand all the ${...} values in a string which may be a
    # full CloudFormation YAML template
    def expand_strings(data)
      # NOTE: previous code to remove comments has been removed; it was removing
      # the comment at the top of user_data, which broke user data.
      while data.match(Expand_Regex)
        data = data.gsub(Expand_Regex) do
          expand_string($1)
        end
      end
      return data
    end

    # resolve_vars performs two types of string value expansion:
    # - When a string is of the form $var, $@var, or $%var, a complex
    #   substitution is performed where the string is replaced by an arbitrary
    #   value, be that another string, a hash, an array, or more complex
    #   structure.
    # - Strings not matching the complex variable patter are passed to
    #   expand_strings to produce another string with all variables expanded.
    #
    # This is used most heavily for API templates. While it is also called for
    # CloudFormation templates, best practices dictate use of stack parameters
    # (which are commonly resolved this way) instead of directly in the
    # template, to preserve compatibility with many 3rd-party CloudFormation
    # templates.
    def resolve_vars(parent, item)
      log(:trace, "Resolving values for #{parent} key: #{item}")
      case parent[item].class().to_s()
      when "Array"
        parent[item].each_index() do |index|
          resolve_vars(parent[item], index)
        end
      when "Hash"
        parent[item].each_key() do |key|
          resolve_vars(parent[item], key)
        end # Hash each
      when "String"
        var = parent[item]
        # Complex value expansion
        if var[0] == '$' and var[1] != '$' and var[1] != '{'
          cfgvar = var[1..-1]
          case cfgvar[0]
          when "@"
            param = cfgvar[1..-1]
            value = getparam(param)
            raise "Reference to undefined parameter \"#{param}\" during data element expansion of \"#{var}\"" unless value
            parent[item] = value
          when "%"
            lookup = cfgvar[1..-1]
            item, key = lookup.split(":")
            raise "Invalid SimpleDB lookup: #{lookup}" unless key
            values = @sdb.retrieve(item, key)
            raise "No values returned from lookup of #{key} in item #{item} from #{@sdb.getdomain()}" unless values.length > 0
            parent[item] = values
          else
            if @config[cfgvar] == nil
              raise "Bad variable reference: \"#{cfgvar}\" not defined in cloudconfig.yaml"
            end
            parent[item] = @config[cfgvar]
          end # case cfgvar[0]
        # String expansion
        else
          expanded = expand_strings(parent[item])
          log(:trace, "Expanded string \"#{parent[item]}\" -> \"#{expanded}\"") if parent[item] != expanded
          parent[item] = expanded
          if parent[item] == "<DELETE>"
            parent.delete(item)
          elsif parent[item] == "<REQUIRED>"
            raise "Missing required value for key #{item}"
          end
        end
      end # case item.class
    end

    # Return the value of a resource property. NOTE: very incomplete; additional
    # types and properties to be added as needed.
    def get_resource_property(restype, resname, property)
      case restype
      when "AWS::IAM::InstanceProfile"
        res = @iamres.instance_profile(resname)
        case property
        when "arn"
          return res.arn
        end
      end
      raise "Unsupported resource type / property: #{restype} / #{property}"
    end

  end # Class CloudManager

end # Module RAWS
