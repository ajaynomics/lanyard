# The person's own Link wallet (User::Wallet, docs/payments.md): connected by
# Link's device sign-in, which shows a phrase to enter at Link, then asks Link
# whether they did; or disconnected, at Link too.
class Settings::WalletsController < ApplicationController
  layout "settings"

  before_action -> { head :not_found unless DurableAssistants::Link.configured? }

  rescue_from DurableAssistants::Link::Error do |error|
    redirect_to settings_wallet_path, alert: error.message, status: :see_other
  end

  def show
  end

  def create
    Current.user.start_wallet_sign_in!
    redirect_to settings_wallet_path, status: :see_other
  end

  def update
    if Current.user.finish_wallet_sign_in!
      redirect_to settings_wallet_path, notice: "Connected. Agents you switch Pay by card on for can ask to pay.", status: :see_other
    else
      redirect_to settings_wallet_path, alert: "Link hasn't had the phrase yet. Enter it on Link's page, then press Done again.", status: :see_other
    end
  end

  def destroy
    Current.user.disconnect_wallet!
    redirect_to settings_wallet_path, notice: "Disconnected.", status: :see_other
  end
end
