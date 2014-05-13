require 'spec_helper'
require 'aws/ec2'
require 'aws-sdk-core'

describe AWS::Ec2 do
  before :all do
    @ec2 = AWS::Ec2.new
  end

  it "should list more than 0 ec2 instances for cost centers and stacks" do
    instances = @ec2.list(['techops'])
    expect(instances.length).to be > 0
  end

  it "should not list any ec2 instances" do
    instances = @ec2.list(['gibberish'])
    expect(instances.length).to eq(0)
  end

  it "should list instances for the 'techops' cost center" do
    instances = @ec2.list(['techops'])
    instance = instances.first
    cost_center = instance.tags.find{|tag| tag.key == @ec2.config.aws[:tags][:cost_center]}.value
    expect(cost_center).to eq("techops")
  end

  it "should not list instances for the 'techops' cost center" do
    instances = @ec2.list(['phix'])
    instance = instances.first
    cost_center = instance.tags.find{|tag| tag.key == @ec2.config.aws[:tags][:cost_center]}.value
    expect(cost_center).not_to eq("techops")
  end

  # it "should start stopped instances due for startup in the 'techops' cost center" do
  #   instances = @ec2.start_instances(["techops"], ["dev"], false, false, false)
  #   expect(instances.first.starting_instances.first.current_state).to eq("pending" || "running")
  #   @ec2.stop_instances(["techops"], ["dev"], false, false, false)
  # end

  it "should raise DryRunOperation when attempting to start stopped instances in the 'techops' cost center" do
    expect{@ec2.start_instances(["techops"], ["dev"], true, false, false)}.to raise_error(Aws::EC2::Errors::DryRunOperation)
  end

  it "should raise DryRunOperation when attempting to stop running instances in the 'techops' cost center" do
    expect{@ec2.stop_instances(["techops"], ["dev"], true, false, false)}.to raise_error(Aws::EC2::Errors::DryRunOperation)
  end

  it "should add missing tags to instances" do
    tagged_instances = @ec2.audit_tags(["techops"], ["dev"], false, false, false)
    instances = @ec2.list(["techops"], ["dev"])
    instances.each do |instance|
      @ec2.config.aws[:tags].each do |k, v|
        expect(instance.tags.find{|tag| tag.key == v}).not_to be_nil
      end
    end
  end
end
