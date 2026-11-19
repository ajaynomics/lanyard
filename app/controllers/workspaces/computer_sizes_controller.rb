# The owner of a shared workspace sets the size its agents' Sprites are made
# with (Computer::Size), within the install's maximum; an agent's own size
# overrides it. Anyone else finds no such workspace.
class Workspaces::ComputerSizesController < ApplicationController
  def update
    @workspace = Current.user.owned_workspaces.shared.find(params[:workspace_id])
    if @workspace.update(params.expect(workspace: %i[ computer_cpus computer_memory_mib computer_disk_mib ]))
      redirect_to @workspace, status: :see_other, notice: "Computers from now on will be #{@workspace.computer_size}."
    else
      render "workspaces/show", status: :unprocessable_entity
    end
  end
end
