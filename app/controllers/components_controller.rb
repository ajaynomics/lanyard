# Every shared piece of the interface on one page, in each of its states, so a
# change that drifts from the rest shows at a glance (docs/design.md). Routed
# only in development and test: a test renders it, so a piece whose locals
# change breaks the build rather than this page.
class ComponentsController < ApplicationController
  def show
    @invalid = Current.user.agents.new.tap { it.validate }
  end
end
