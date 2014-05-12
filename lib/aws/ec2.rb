module Aws
  class Ec2
    attr_reader :config
    attr_reader :logger
    attr_reader :administrator
    @ec2 = nil
    @ses = nill

    ALL = "all"

    def initialize
      # bootstrap
      @config = Configuration.new
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

    def list(cost_center, stack, *options)
  		@logger.progname = "#{self.class.name}:#{__method__.to_s}"
  		@logger.info {"[Start] #{__method__.to_s}"}

  		# look up instances
  		filters = Array.new
  		filters << {name: "tag:cost-center", values: cost_center}
  		filters << {name: "tag:stack", values: stack} unless stack.nil?

  		resp = desc_instances(filters)

  		# list instances
  		resp.reservations.each do |reservation|
  			reservation.instances.each do |instance|
  				begin
  					@logger.info {
  						"#{instance.instance_id}: #{instance.tags.find{|tag| tag.key == "Name"}.value} (#{instance.state.name}), " +
  						"StartTime: #{instance.tags.find{|tag| tag.key == "starttime"}.value}, " +
  						"StopTime: #{instance.tags.find{|tag| tag.key == "stoptime"}.value}, " +
  						"Expires: #{instance.tags.find{|tag| tag.key == "expires"}.value}, " +
  						"Owner: #{instance.tags.find{|tag| tag.key == "owner"}.value}, " +
  						"InstanceType: #{instance.instance_type}"
  					}
  				rescue Exception => e
  					@logger.error e
  					e.backtrace.each { |line| @logger.error line }
  					send_notification([@administrator, "#{@logger.progname} failed - #{instance.instance_id}",
  					"Instance listing failed - #{e.message}\n #{e.backtrace}") unless @administrator.nil?
  				end
  			end
  		end
  		@logger.info {"[Stop] #{__method__.to_s}"}
  	end
  end
end
