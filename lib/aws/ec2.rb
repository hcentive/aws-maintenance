require 'aws-sdk-core'
require 'aws/configuration'
require 'logger'

module AWS
  class Ec2
    attr_reader :config
    attr_reader :logger
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

    # list instances
    def list(cost_center, stack=nil, *options)
  		@logger.progname = "#{self.class.name}:#{__method__.to_s}"
  		@logger.info {"[Start] #{__method__.to_s}"}

  		# look up instances
  		filters = Array.new
  		filters << {name: "tag:#{@config.aws[:tags][:cost_center]}", values: cost_center}
  		filters << {name: "tag:#{@config.aws[:tags][:stack]}", values: stack} unless stack.nil?

  		resp = desc_instances(filters)

      instances = []

  		# list instances
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

    def start_instances(cost_center, stack=nil, dry_run=false, notify_owner=true, continue_on_error=true, *options)
  		@logger.progname = "#{self.class.name}:#{__method__.to_s}"
  		@logger.info {"[Start] #{__method__.to_s}"}
  		filters = Array.new
  		filters << {name: "instance-state-name", values: ["stopped"]}
      filters << {name: "tag:#{@config.aws[:tags][:cost_center]}", values: cost_center}
      filters << {name: "tag:#{@config.aws[:tags][:stack]}", values: stack} unless stack.nil?

  		resp = desc_instances(filters)

  		#start each instance that has "StartTime" tag value for the past hour
  		resp.reservations.each do |reservation|
  			reservation.instances.each do |instance|
  				begin
  					starttime = instance.tags.find{|tag| tag.key == "#{@config.aws[:tags][:start_time]}"}.value
  					if !starttime.nil? and Time.parse(starttime) >= Time.now then
							start_instance(instance, dry_run, notify_owner)
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
  	end

    def stop_instances(cost_center, stack=nil, dry_run=false, notify_owner=true, continue_on_error=true, *options)
  		@logger.progname = "#{self.class.name}:#{__method__.to_s}"
  		@logger.info {"[Start] #{__method__.to_s}"}
  		filters = Array.new
  		filters << {name: "instance-state-name", values: ["running"]}
  		filters << {name: "tag:#{@config.aws[:tags][:cost_center]}", values: cost_center}
      filters << {name: "tag:#{@config.aws[:tags][:stack]}", values: stack} unless stack.nil?

  		resp = desc_instances(filters)

  		#stop each instance that has "stoptime" tag value for the next hour
  		resp.reservations.each do |reservation|
  			reservation.instances.each do |instance|
  				begin
  					stoptime = instance.tags.find{|tag| tag.key == "#{@config.aws[:tags][:stop_time]}"}.value
  					if !stoptime.nil? and Time.parse(stoptime) < Time.now + @config.aws[:shutdown_pre] then
							stop_instance(instance, dry_run, notify_owner)
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
  	end

    private

    # describe_instances
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

    # Stops an instance
		def stop_instance(instance, dryrun, notify)
			name = instance.tags.find{|tag| tag.key == "Name"}.value
			@logger.info {"Stopping instance - #{name} (#{instance.instance_id})"}
			@ec2.stop_instances(dry_run: dryrun.to_s, instance_ids: [instance.instance_id])
			if notify then
				owner = instance.tags.find{|tag| tag.key == "#{@config.aws[:tags][:owner]}"}.value.to_s
				msg_id = send_notification([owner, @administrator], "Instance stopped - #{instance.instance_id}",
				"Dear #{owner},\n\nYour instance (#{name}) has been stopped.\n\nRegards,\nTechOps")
				@logger.info {"Notified owner #{owner}; message id - #{msg_id.data.message_id.to_s}"}
			end
		end

    # Starts an instance
		def start_instance(instance, dryrun, notify)
			name = instance.tags.find{|tag| tag.key == "Name"}.value
			@logger.info {"Starting instance - #{name} (#{instance.instance_id})"}
			@ec2.start_instances(dry_run: dryrun.to_s, instance_ids: [instance.instance_id])
			if notify then
				owner = instance.tags.find{|tag| tag.key == "#{@config.aws[:tags][:owner]}"}.value.to_s
				msg_id = send_notification([owner, @administrator], "Instance started - #{instance.instance_id}",
				"Dear #{owner},\n\nYour instance (#{name}) has been started.\n\nRegards,\nTechOps")
				@logger.info {"Notified owner #{owner}; message id - #{msg_id.data.message_id.to_s}"}
			end
		end

    # Updates instance tags
		def tag_instance(instance, tags, dryrun, notify)
			@logger.info {"Tagging instance - #{instance.instance_id} with - #{tags}"}
			@ec2.create_tags(dry_run: dryrun.to_s, resources: [instance.instance_id], tags: tags)
			if notify && !instance.tags.find{|tag| tag.key == "owner"}.nil? && !instance.tags.find{|tag| tag.key == "owner"}.value.nil? then
				owner = instance.tags.find{|tag| tag.key == "#{@config.aws[:tags][:owner]}"}.value.to_s
				msg_id = send_notification([owner, @administrator], "Audit AWS Tags : instance tags updated - #{instance.instance_id}",
				"Dear #{owner},\n\nTags for your instance (#{instance.instance_id}) have been updated.\n\nRegards,\nTechOps")
				@logger.info {"Notified owner #{owner}; message id - #{msg_id.data.message_id.to_s}"}
			end
		end

    # Send email notification
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
