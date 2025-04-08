require 'helper'
require 'fluent/plugin/filter_time_cutoff.rb'

class TimeCutoffFilterTest < Test::Unit::TestCase
  setup do
    Fluent::Test.setup
  end

  test 'failure' do
    flunk
  end

  private

  def create_driver(conf)
    Fluent::Test::Driver::Filter.new(Fluent::Plugin::TimeCutoffFilter).configure(conf)
  end
end
