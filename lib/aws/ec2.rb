require 'aws-sdk-core'
require 'aws/configuration'
require 'logger'

module AWS
  # @author Satyendra Sharma <satyendra.sharma@hcentive.com>
  # Utility class to maintain EC2 instances
  class Ec2
    # @return [Configuration] Returns configuration for the instance.
    attr_reader :config
    # @return [Logger] Returns logger for this instance.
    attr_reader :logger
    # @return Returns administrator's email address
    attr_reader :administrator

    @ec2 = nil
    @ses = nil

    ALL = "all"

    def initialize
      # bootstrap
      @config = AWS::Configuration.new
      loghome = @config.logger[:home]
    	Dir.mkdir(loghome) unless Dir.exist?(loghome)
    	loghome.concat(@config.logger[:file])
    	logfile = File.open(loghome, "a+")
    	@logger = Logger.new(logfile, 'daily')
    	@logger = Logger.new(logfile, 'weekly')
    	@logger = Logger.new(logfile, 'monthly')
    	@logger.level = Logger::INFO
    	@logger.formatter = proc do |severity, datetime, progname, msg|
    		"[#{datetime}] : #{severity} : #{progname} - #{msg}\n"
    	end

      if !@config.mail[:administrator].nil? then
    	   @administrator = @config.mail[:administrator]
      end

      # initialize aws objects
      @ec2 = Aws::EC2.new
      @ses = Aws::SES.new
    end

    # Returns a list of instances for a a list of cost centers and stacks.
    # @param cost_center [Array] the list of cost centers e.g. ["techops", "phix", "hix"]
    # @param stack [Array] the list of stacks for the cost center e.g. ["dev", "qa", "demo"]
    # @param options [Hash] hash of options
    # @return instances [Array] the list of instancs for the cost centers and stacks
    def list(cost_center, stack=nil, *options)
  		@logger.progname = "#{self.class.name}:#{__method__.to_s}"
  		@logger.info {"[Start] #{__method__.to_s}"}

  		# look up instances
  		filters = Array.new
  		filters << {name: "tag:#{@config.aws[:tags][:cost_center]}", values: cost_center}
  		filters << {name: "tag:#{@config.aws[:tags][:stack]}", values: stack} unless stack.nil?

  		resp = desc_instances(filters)

      instances = []

  		resp.reservations.each do |reservation|
  			reservation.instances.each do |instance|
  				begin
  					@logger.info {
  						"#{instance.instance_id}: #{instance.tags.find{|tag| tag.key == "Name"}.value} (#{instance.state.name}), " +
  						"StartTime: #{instance.tags.find{|tag| tag.key == "#{@config.aws[:tags][:start_time]}"}.value}, " +
  						"StopTime: #{instance.tags.find{|tag| tag.key == "#{@config.aws[:tags][:stop_time]}"}.value}, " +
  						"Expires: #{instance.tags.find{|tag| tag.key == "#{@config.aws[:tags][:expiry_date]}"}.value}, " +
  						"Owner: #{instance.tags.find{|tag| tag.key == "#{@config.aws[:tags][:owner]}"}.value}, " +
  						"InstanceType: #{instance.instance_type}"
  					}
            instances << instance
  				rescue Exception => e
  					@logger.error e
  					e.backtrace.each { |line| @logger.error line }
  					send_notification([@administrator], "#{@logger.progname} failed - #{instance.instance_id}", "Instance listing failed - #{e.message}\n #{e.backtrace}") unless @administrator.nil?
  				end
  			end
  		end
      @logger.info {"[Stop] #{__method__.to_s}"}
      instances
  	end

    # Starts instances for the specified cost centers and stacks.
    # @param cost_center [Array] the list of cost centers e.g. ["techops", "phix", "hix"]
    # @param stack [Array] the list of stacks for the cost center e.g. ["dev", "qa", "demo"]
    # @param dry_run [Boolean] dry run; default - false
    # @param notify_owner [Boolean] send email notification to instance owner; default - true
    # @param continue_on_error [Boolean] continue if one or more instances fail to start; default - true
    # @param options [Hash] hash of options
    def start_instances(cost_center, stack=nil, dry_run=false, notify_owner=true, continue_on_error=true, *options)
  		@logger.progname = "#{self.class.name}:#{__method__.to_s}"
  		@logger.info {"[Start] #{__method__.to_s}"}
  		filters = Array.new
  		filters << {name: "instance-state-name", values: ["stopped"]}
      filters << {name: "tag:#{@config.aws[:tags][:cost_center]}", values: cost_center}
      filters << {name: "tag:#{@config.aws[:tags][:stack]}", values: stack} unless stack.nil?

  		resp = desc_instances(filters)

      instances = []

  		#start each instance that has "StartTime" tag value for the past hour
  		resp.reservations.each do |reservation|
  			reservation.instances.each do |instance|
  				begin
  					starttime = instance.tags.find{|tag| tag.key == "#{@config.aws[:tags][:start_time]}"}.value
  					if !starttime.nil? and Time.parse(starttime) >= Time.now then
							instances << start_instance(instance, dry_run, notify_owner)
  					end
  				rescue Aws::Errors::ServiceError => e
  					@logger.error e
  					e.backtrace.each { |line| @logger.error line }
  					send_notification([@administrator], "#{@logger.progname} failed", "start_instance failed - #{e.message} \n\n#{e.backtrace}.") unless @administrator.nil?
            raise e unless continue_on_error
  				end
  			end
  		end
  		send_notification([@administrator], "#{@logger.progname} run complete", "#{@logger.progname} run ended at #{Time.now}") unless @administrator.nil?
  		@logger.info {"[Stop] #{__method__.to_s}"}
      instances
  	end

    # Stops instances for the specified cost centers and stacks.
    # @param cost_center [Array] the list of cost centers e.g. ["techops", "phix", "hix"]
    # @param stack [Array] the list of stacks for the cost center e.g. ["dev", "qa", "demo"]
    # @param dry_run [Boolean] dry run; default - false
    # @param notify_owner [Boolean] send email notification to instance owner; default - true
    # @param continue_on_error [Boolean] continue if one or more instances fail to stop; default - true
    # @param options [Hash] hash of options
    def stop_instances(cost_center, stack=nil, dry_run=false, notify_owner=true, continue_on_error=true, *options)
  		@logger.progname = "#{self.class.name}:#{__method__.to_s}"
  		@logger.info {"[Start] #{__method__.to_s}"}
  		filters = Array.new
  		filters << {name: "instance-state-name", values: ["running"]}
  		filters << {name: "tag:#{@config.aws[:tags][:cost_center]}", values: cost_center}
      filters << {name: "tag:#{@config.aws[:tags][:stack]}", values: stack} unless stack.nil?

  		resp = desc_instances(filters)

      instances = []

  		#stop each instance that has "stoptime" tag value for the next hour
  		resp.reservations.each do |reservation|
  			reservation.instances.each do |instance|
  				begin
  					stoptime = instance.tags.find{|tag| tag.key == "#{@config.aws[:tags][:stop_time]}"}.value
  					if !stoptime.nil? and Time.parse(stoptime) < Time.now + @config.aws[:shutdown_pre] then
							instances << stop_instance(instance, dry_run, notify_owner)
  					end
  				rescue Aws::Errors::ServiceError => e
  					@logger.error e
  					e.backtrace.each { |line| @logger.error line }
  					send_notification([@administrator], "#{@logger.progname} failed", "stop_instance failed - #{e.message} \n\n#{e.backtrace}.")
            raise e unless continue_on_error
  				end
  			end
  		end
  		send_notification([@administrator], "#{@logger.progname} run complete", "#{@logger.progname} run ended at #{Time.now}")
  		@logger.info {"[Stop] #{__method__.to_s}"}
      instances
  	end

    # Audits and creates missing instance tags for the specified cost centers and stacks.
    # Tag names are defined in config.yml.
    # @param cost_center [Array] the list of cost centers e.g. ["techops", "phix", "hix"]
    # @param stack [Array] the list of stacks for the cost center e.g. ["dev", "qa", "demo"]
    # @param dry_run [Boolean] dry run; default - false
    # @param notify_owner [Boolean] send email notification to instance owner; default - true
    # @param continue_on_error [Boolean] continue if one or more instances fail to stop; default - true
    # @param options [Hash] hash of options
    def audit_tags(cost_center, stack=nil, dry_run=false, notify_owner=true, continue_on_error=true, *options)
  		@logger.progname = "#{self.class.name}:#{__method__.to_s}"
  		@logger.info {"[Start] #{__method__.to_s}"}

  		# look up instances
  		filters = Array.new
  		filters << {name: "tag:#{@config.aws[:tags][:cost_center]}", values: cost_center}
      filters << {name: "tag:#{@config.aws[:tags][:stack]}", values: stack} unless stack.nil?

  		resp = desc_instances(filters)

      tagged_instances = []

  		update_tags = false

  		resp.reservations.each do |reservation|
  			reservation.instances.each do |instance|
  				begin
  					tags = Array.new
  					@config.aws[:tags].each do |k, v|
  						update_tags = true if instance.tags.find{|tag| tag.key == v}.nil?
  						val = instance.tags.find{|tag| tag.key == v}.nil? ? "" : instance.tags.find{|tag| tag.key == v}.value
  						tags << {key: v, value: val}
  					end
  					if update_tags then
							tagged_instances << tag_instance(instance, tags, dry_run, notify_owner)
  					end
  				rescue Aws::Errors::ServiceError => e
  					@logger.error e
  					e.backtrace.each { |line| @logger.error line }
  					send_notification([@administrator], "#{@logger.progname} failed", "audit_tags failed - #{e.message} \n\n#{e.backtrace}.")
            raise e unless continue_on_error
  				ensure
  					update_tags = false
  				end
  			end
  		end

  		@logger.info {"[Stop] #{__method__.to_s}"}
      tagged_instances
  	end

    private

    # Describe EC2 instances.
    # @param filters [Array] array of hashes to appy filters on
    # @return resp [PageableResponse] {http://docs.aws.amazon.com/sdkforruby/api/Aws/PageableResponse.html Aws:PageableResponse} object
		def desc_instances(filters)
			begin
				resp = @ec2.describe_instances(filters: filters)
			rescue Aws::Errors::ServiceError => e
				@logger.error e
				e.backtrace.each { |line| @logger.error line }
				send_notification([@administrator], "#{@logger.progname} initialization failed", "ec2.describe_instances failed - #{e.message} \n\n#{e.backtrace}.") unless @administrator.nil?
				raise e
			end
		end

    # Stop an EC2 instance.
    # @param instance [Instance] instance object
    # @param dryrun [Boolean] dry run; default - false
    # @param notify [Boolean] notify instance owner; default - true
    # @return resp [PageableResponse] {http://docs.aws.amazon.com/sdkforruby/api/Aws/PageableResponse.html Aws:PageableResponse} object
		def stop_instance(instance, dryrun=false, notify=true)
			name = instance.tags.find{|tag| tag.key == "Name"}.value
			@logger.info {"Stopping instance - #{name} (#{instance.instance_id})"}
			resp = @ec2.stop_instances(dry_run: dryrun.to_s, instance_ids: [instance.instance_id])
			if notify then
				owner = instance.tags.find{|tag| tag.key == "#{@config.aws[:tags][:owner]}"}.value.to_s
				msg_id = send_notification([owner, @administrator], "Instance stopped - #{instance.instance_id}",
				"Dear #{owner},\n\nYour instance (#{name}) has been stopped.\n\nRegards,\nTechOps")
				@logger.info {"Notified owner #{owner}; message id - #{msg_id.data.message_id.to_s}"}
			end
      resp
		end

    # Starts an instance.
    # @param instance [Instance] instance object
    # @param dryrun [Boolean] dry run; default - false
    # @param notify [Boolean] notify instance owner; default - true
    # @return resp [PageableResponse] {http://docs.aws.amazon.com/sdkforruby/api/Aws/PageableResponse.html Aws:PageableResponse} object
		def start_instance(instance, dryrun, notify)
			name = instance.tags.find{|tag| tag.key == "Name"}.value
			@logger.info {"Starting instance - #{name} (#{instance.instance_id})"}
			resp = @ec2.start_instances(dry_run: dryrun.to_s, instance_ids: [instance.instance_id])
			if notify then
				owner = instance.tags.find{|tag| tag.key == "#{@config.aws[:tags][:owner]}"}.value.to_s
				msg_id = send_notification([owner, @administrator], "Instance started - #{instance.instance_id}",
				"Dear #{owner},\n\nYour instance (#{name}) has been started.\n\nRegards,\nTechOps")
				@logger.info {"Notified owner #{owner}; message id - #{msg_id.data.message_id.to_s}"}
			end
      resp
		end

    # Updates instance tags
    # @param instance [Instance] instance object
    # @param tags [Array] array of hashes containing name/value pairs for tags
    # @param dryrun [Boolean] dry run; default - false
    # @param notify [Boolean] notify instance owner; default - true
    # @return resp [PageableResponse] {http://docs.aws.amazon.com/sdkforruby/api/Aws/PageableResponse.html Aws:PageableResponse} object
		def tag_instance(instance, tags, dryrun, notify)
			@logger.info {"Tagging instance - #{instance.instance_id} with - #{tags}"}
			resp = @ec2.create_tags(dry_run: dryrun.to_s, resources: [instance.instance_id], tags: tags)
			if notify && !instance.tags.find{|tag| tag.key == "owner"}.nil? && !instance.tags.find{|tag| tag.key == "owner"}.value.nil? then
				owner = instance.tags.find{|tag| tag.key == "#{@config.aws[:tags][:owner]}"}.value.to_s
				msg_id = send_notification([owner, @administrator], "Audit AWS Tags : instance tags updated - #{instance.instance_id}",
				"Dear #{owner},\n\nTags for your instance (#{instance.instance_id}) have been updated.\n\nRegards,\nTechOps")
				@logger.info {"Notified owner #{owner}; message id - #{msg_id.data.message_id.to_s}"}
			end
      resp
		end

    # Send email notification
    # @param to [String] to address
    # @param subject [String] email subject
    # @param msg [String] email body
		# TODO: use email templates
		def send_notification(to, subject, msg)
			to.each {|addr| addr << "@hcentive.com" unless addr.end_with?("@hcentive.com")}
			msg_id = @ses.send_email(
  			source: "noreply-product-demo@hcentive.com",
  			destination: {
  				to_addresses: to
  			},
  			message: {
  				subject: {
  					data: subject
  				},
  				body: {
  					text: {data: msg}
  				}
  			}
			)
			@logger.info {"Sent notification to #{to} : message id - #{msg_id.data.message_id.to_s}"}
			return msg_id
		end
  end
end
