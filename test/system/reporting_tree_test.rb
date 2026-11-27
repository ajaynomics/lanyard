require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

class ReportingTreeTest < ApplicationSystemTestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @owner = User.find_by!(oidc_sub: "42")
    @workspace = Workspace.make(name: "Juniper Studio", owner: @owner)
    @aster, @rill, @pip, @sable, @cove = %w[ Aster Rill Pip Sable Cove ].map { @owner.start_agent(it, workspace: @workspace) }
    @rill.update!(parent_id: @aster.id)
    @pip.update!(parent_id: @rill.id)
    @cove.conversation.archive
    [ @aster, @rill, @pip, @sable ].each do |agent|
      thread = agent.conversation
      thread.update!(durable_id: "d-#{thread.id}")
    end
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/[^/]+/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/[^/?]+(\?.*)?\z}).to_return(body: { status: "idle" }.to_json)
  end
  teardown do
    page.current_window.resize_to(1400, 1400)
    remove_sidecar_settings
  end

  test "reports start open and remember changes across reloads" do
    page.current_window.resize_to(390, 844)
    visit conversations_path
    within(group) { assert_link "Pip" }
    within(group) { toggle_reports("Hide", @aster) }
    assert_no_selector "#{group} #{row(@pip)}"
    assert_selector "#{group} summary[aria-label='Show reports for #{@aster}']"
    refresh
    assert_no_selector "#{group} #{row(@pip)}"
    within(group) { toggle_reports("Show", @aster) }
    assert_selector "#{group} #{row(@pip)}"
    assert_selector "#{group} summary[aria-label='Hide reports for #{@aster}']"
    refresh
    assert_selector "#{group} #{row(@pip)}"
  end

  test "on the phone reports expand, indent and move with their branch" do
    page.current_window.resize_to(390, 844)
    visit root_path
    within(group) do
      assert_link "Rill"
      assert_selector ".tree-toggle[title='1 direct report']", text: "1"
      assert_selector ".tree-children .tree-children .conversation-row__name", text: "Pip"
      assert_no_text "Reports to"
      geometry = page.evaluate_script(<<~JS, reports(@aster))
        (selector => {
          const rail = document.querySelector(selector)
          const root = rail.closest('.tree-branch')
          const leaf = rail.querySelector(':scope > .tree-branch > details > .tree-children > .tree-branch')
          return [getComputedStyle(rail).borderInlineStartWidth, leaf.getBoundingClientRect().left - root.getBoundingClientRect().left,
            document.documentElement.scrollWidth - window.innerWidth]
        })(arguments[0])
      JS
      assert_equal [ "1px", 24, 0 ], geometry
      toggle_reports("Hide", @aster)
      assert_no_link "Pip"
      toggle_reports("Show", @aster)
      assert_link "Pip"
    end
    open_picker(@rill)
    within("dialog[open]") do
      assert_no_text "Pip"
      assert_no_text "Cove"
      assert_no_field "Rill", type: :radio
      assert_text "1 direct report will move with Rill"
      choose "Sable", allow_label_click: true
      assert_text "Rill will report to Sable"
      click_button "Move agent"
    end
    assert_no_selector "dialog.tree-picker[open]"
    assert_selector "#{reports(@sable)} #{row(@rill)}"
    assert_selector "#{reports(@sable)} #{reports(@rill)} #{row(@pip)}"
    assert_selector "#reporting_actions_agent_#{@rill.id}:focus"
    assert_selector "#reporting_status", text: "Rill now reports to Sable"
    refresh
    assert_selector "#{reports(@sable)} #{row(@rill)}"
  end

  test "on desktop the selected path opens and the keyboard picker leaves a draft alone" do
    page.current_window.resize_to(1280, 800)
    visit conversation_path(@pip.conversation)
    wait_for_live_updates
    within(".chat-sidebar") do
      assert_selector "#{reports(@aster)} #{reports(@rill)} [aria-current=page]", text: "Pip"
      find("#{row(@pip)} a").send_keys(:home)
      assert_selector ".conversation-row__link:focus"
    end
    fill_in "Message Pip", with: "Keep this draft"
    within(".chat-sidebar") { find("#reporting_actions_agent_#{@rill.id}").send_keys(:enter) }
    find_link("Move in reporting tree…").send_keys(:enter)
    assert_selector "dialog.tree-picker[open] input:checked:focus", count: 1
    page.active_element.send_keys(:escape)
    assert_no_selector "dialog.tree-picker[open]"
    assert_selector "#reporting_actions_agent_#{@rill.id}:focus"

    open_picker(@rill)
    find("dialog.tree-picker input:checked").send_keys(:down)
    assert_selector "dialog.tree-picker input[value='#{@sable.id}']:checked"
    page.active_element.send_keys(:tab, :tab, :enter)
    assert_selector ".chat-sidebar #{reports(@sable)} #{row(@rill)}"
    assert_field "Message Pip", with: "Keep this draft"
  end

  test "a report's sidebar avatar is indented past its manager with a toggle" do
    visit conversation_path(@pip.conversation)
    within(".chat-sidebar #{group}") do
      assert_selector "summary[aria-label='Hide reports for #{@rill}']"
      manager = find("#{row(@rill)} .ui-avatar")
      report = find("#{reports(@rill)} #{row(@pip)} .ui-avatar")
      assert_operator report.rect.x, :>, manager.rect.x
    end
  end

  test "the selected sidebar row is highlighted edge to edge including its menu" do
    page.current_window.resize_to(700, 844)
    visit conversation_path(@pip.conversation)
    click_button "Agents"
    within("#agents_panel[open]") do
      link = find("#{row(@pip)} [aria-current=page]")
      menu = find("#reporting_actions_agent_#{@pip.id}")
      left, right, paint_left, paint_right, menu_inside = link.evaluate_script(<<~JS, menu)
        (() => {
          const row = this.closest('.tree-row')
          const hasPaint = element => getComputedStyle(element).backgroundColor !== 'rgba(0, 0, 0, 0)'
          const highlight = [this, row].find(hasPaint)?.getBoundingClientRect()
          const bounds = row.getBoundingClientRect()
          const menu = arguments[0].getBoundingClientRect()
          const inside = highlight && menu.left >= highlight.left && menu.right <= highlight.right &&
            menu.top >= highlight.top && menu.bottom <= highlight.bottom
          return [bounds.left, bounds.right, highlight?.left, highlight?.right, inside]
        })()
      JS
      assert paint_left, "the selected row has a highlight"
      assert_in_delta left, paint_left, 1, "highlight starts at the row's left edge"
      assert_in_delta right, paint_right, 1, "highlight ends at the row's right edge"
      assert menu_inside, "the menu is inside the highlight"

      link.send_keys(:shift)
      rings = link.evaluate_script("[getComputedStyle(this).outlineStyle, getComputedStyle(this.closest('.tree-row')).outlineStyle]")
      assert_equal [ "none", "solid" ], rings, "the focus ring outlines the row, not the link inside it"
    end
  end

  test "deleting a manager names the destination and leaves its report there" do
    page.current_window.resize_to(390, 844)
    visit agent_path(@rill)
    within("#delete_agent") do
      assert_text "move up to Aster"
      fill_in "Type Rill to confirm", with: "Rill"
      click_button "Delete Rill"
    end
    assert_selector "h1", text: "Agents"
    assert_selector "#{reports(@aster)} #{row(@pip)}"
    assert_no_link "Rill"
  end

  test "a structural broadcast redraws the branch in the sidebar without a page visit" do
    page.current_window.resize_to(1280, 800)
    visit conversation_path(@pip.conversation)
    wait_for_live_updates
    @rill.update!(parent_id: @sable.id)
    assert_selector ".chat-sidebar #{reports(@sable)} #{row(@rill)}"
    @pip.conversation.update!(status: "running")
    assert_selector ".chat-sidebar #{reports(@sable)} #{row(@pip)}[data-standing=working]"
    assert_current_path conversation_path(@pip.conversation)
  end

  test "a collapsed sidebar group shows when a report starts waiting" do
    visit conversation_path(@sable.conversation)
    wait_for_live_updates
    within(".chat-sidebar #{group}") do
      badge = ".tree-branch[data-agent='#{@aster.id}'] > .tree-row .tree-waiting"
      assert_selector "#{row(@pip)}[data-waiting='0']"
      toggle_reports("Hide", @aster)
      assert_no_selector row(@pip)
      assert_no_selector badge

      @pip.conversation.invocations.create!(task_id: "7", call_id: "sidebar-wait", tool_name: "ask_person",
        arguments: { "question" => "Which plan?" }, digest: "sidebar-wait", state: "awaiting_person", expires_at: 1.day.from_now)
      @pip.conversation.update!(status: "waiting")

      assert_selector "#{row(@pip)}[data-waiting='1']", visible: :hidden
      assert_selector badge, exact_text: "1 waiting below"
    end
  end

  test "a remembered or direct chart stays an indented List on a phone" do
    page.current_window.resize_to(1280, 844)
    visit conversations_path(lens: "chart")
    assert_selector ".agent-lenses [aria-current=page]", text: "Chart"
    page.current_window.resize_to(390, 844)
    [ conversations_path, conversations_path(lens: "chart") ].each do |path|
      visit path
      assert_no_selector ".agent-lenses"
      leaf = find("#{reports(@aster)} #{reports(@rill)} #{row(@pip)}")
      assert_equal 24, leaf.evaluate_script("this.closest('.tree-branch').getBoundingClientRect().left - this.closest('.tree').firstElementChild.getBoundingClientRect().left")
    end
    find("#{row(@pip)} a").click
    assert_current_path conversation_path(@pip.conversation)
  end

  test "on a phone an open thread's Agents goes back to the indented list" do
    page.current_window.resize_to(390, 844)
    visit conversation_path(@pip.conversation)
    # A phone has no side panel over the thread: Agents is a way back, as Messages has.
    assert_no_button "Agents"
    click_link "Agents"
    assert_current_path root_path
    assert_selector "h1", text: "Agents"
    assert_no_selector ".agent-lenses"
    leaf = find("#{reports(@aster)} #{reports(@rill)} #{row(@pip)}")
    assert_equal 24, leaf.evaluate_script("this.closest('.tree-branch').getBoundingClientRect().left - this.closest('.tree').firstElementChild.getBoundingClientRect().left")
  end

  test "sorting the All view through Turbo keeps managers above their reports" do
    page.current_window.resize_to(390, 844)
    visit conversations_path(lens: "chart")
    find('summary[aria-label="Sort and filter"]').click
    select "Name", from: "Sort"
    assert_current_path(/sort=title/)
    select "All", from: "Show"
    assert_current_path(/filter=all/)
    assert_selector "#{reports(@aster)} #{reports(@rill)} #{row(@pip)}"
    assert_selector row(@cove), text: "Archived"
  end

  test "a chart card updates in place from working to needs you and idle" do
    page.current_window.resize_to(1280, 844)
    visit conversations_path(lens: "chart")
    wait_for_live_updates
    card = ".tree--chart #{row(@pip)}"
    assert_selector "#{card}[data-standing='idle']"
    execute_script("document.body.dataset.chartTest = 'still here'")

    @pip.conversation.update!(status: "running")
    assert_selector "#{card}[data-standing='working'] .conversation-row__marker i", count: 3
    call = @pip.conversation.invocations.create!(task_id: "7", call_id: "chart-wait", tool_name: "ask_person",
      arguments: { "question" => "Which plan?" }, digest: "chart-wait", state: "awaiting_person", expires_at: 1.day.from_now)
    @pip.conversation.update!(status: "waiting")
    assert_selector "#{card}[data-standing='needs_you'][data-waiting='1'] .conversation-row__waiting", text: "1 needs you"
    assert_no_selector "#{card} .conversation-row__marker i"
    assert_not_equal "none", find(card).evaluate_script("getComputedStyle(this.parentElement).boxShadow")

    call.update!(state: "denied")
    @pip.conversation.update!(status: "idle")
    assert_selector "#{card}[data-standing='idle'][data-waiting='0']"
    assert_no_selector "#{card} .conversation-row__waiting"
    assert_selector "body[data-chart-test='still here']"
  end

  { group: "Workspace settings", row: "Move in reporting tree…" }.each do |kind, label|
    test "the #{kind} menu stays compact and opens beside its trigger" do
      [ 390, 1280 ].each do |width|
        page.current_window.resize_to(width, 844)
        visit conversations_path
        trigger = find(kind == :group ? "#{group} .agent-group__more" : "#reporting_actions_agent_#{@rill.id}")
        selector = "##{trigger['popovertarget']}:popover-open"
        trigger.click
        menu = find(selector) do |popover|
          popover.evaluate_script("!this.getAnimations().some(it => it.transitionProperty === 'translate' && it.playState !== 'finished')")
        end
        assert_link label
        distance, inside, compact = menu.evaluate_script(<<~JS, trigger)
          (() => {
            const menu = this.getBoundingClientRect()
            const trigger = arguments[0].getBoundingClientRect()
            return [Math.min(Math.abs(menu.top - trigger.bottom), Math.abs(trigger.top - menu.bottom)),
              menu.top >= 0 && menu.left >= 0 && menu.bottom <= innerHeight && menu.right <= innerWidth,
              menu.width <= 300]
          })()
        JS
        assert_operator distance, :<=, 12, "#{kind} menu should be anchored at #{width}px"
        assert inside, "#{kind} menu should fit the viewport"
        assert compact, "#{kind} menu should fit its items"

        page.active_element.send_keys(:escape)
        assert_no_selector selector
        trigger.click
        assert_selector selector
        find("h1", text: "Agents").click
        assert_no_selector selector
      end
    end
  end

  private
    def group = "#group_workspace_#{@workspace.id}"
    def row(agent) = "#row_conversation_#{agent.conversation.id}"
    def reports(agent) = "#reports_agent_#{agent.id}"

    def toggle_reports(action, agent)
      find("summary[aria-label='#{action} reports for #{agent}']").click
    end

    def open_picker(agent)
      find("#reporting_actions_agent_#{agent.id}").click
      # On a phone the menu is visible while sliding; Archive can cross the click point.
      menu = find("#row_menu_agent_#{agent.id}:popover-open") do |sheet|
        sheet.evaluate_script("!this.getAnimations().some(it => it.transitionProperty === 'translate' && it.playState !== 'finished')")
      end
      menu.find_link("Move in reporting tree…", obscured: false).click
      assert_selector "dialog.tree-picker[open]", text: "Move #{agent}"
    end
end
