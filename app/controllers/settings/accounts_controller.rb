# You: who is signed in, the name the app calls them by, and signing out.
class Settings::AccountsController < ApplicationController
  layout "settings"

  def show
  end

  def update
    if Current.user.update(params.expect(user: [ :name ]))
      saved settings_account_path
    else
      render :show, status: :unprocessable_entity
    end
  end
end
