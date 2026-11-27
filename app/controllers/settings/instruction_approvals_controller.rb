class Settings::InstructionApprovalsController < ApplicationController
  def update
    raise ActiveRecord::RecordNotFound unless Current.admin?

    choice = params.expect(app: [ :own_instruction_approval ]).fetch(:own_instruction_approval)
    DurableAssistants.own_instruction_approval = { "1" => true, "0" => false, "" => nil }.fetch(choice) { raise ActionController::BadRequest }
    saved(workspaces_path)
  end
end
