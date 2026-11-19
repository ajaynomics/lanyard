# The page a link for someone outside opens (SignInLink): a plain form for
# one entry's username, password and account. Opening it uses nothing up,
# since mail scanners fetch links before people do; only its submit does
# (SignInLinks::FillsController).
class SignInLinksController < ApplicationController
  # Counted before the link is looked up, so unknown tokens count too.
  rate_limit to: 30, within: 1.minute, name: "sign_in_links"
  include SignInLinkVisited

  def show
    refused unless @link.open?
  end
end
