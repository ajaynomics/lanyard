# What New agent shows under the name as it is typed: the address the agent
# will write from, which can't be changed once it is made.
class Agents::AddressesController < ApplicationController
  def show
    @name = params[:name].to_s.squish
  end
end
