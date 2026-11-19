# A person's Message or Cancel for a helper or a workflow's run, from its line
# in the thread or the Helpers panel. The change broadcasts the line and the
# panels afresh (Helper, ListedInHelpersPanel), stamped so nothing older
# replaces them; that broadcast is what the page shows next. So a Turbo
# request gets no page back, only an alert when the change was refused: a page
# fetched meanwhile could land over a newer broadcast. Without Turbo, it goes
# back to the page it came from.
module RedrawnByBroadcast
  private
    def redrawn_by_broadcast(done, refusal:, fallback:)
      respond_to do |format|
        format.turbo_stream do
          if done
            render turbo_stream: ""
          else
            render turbo_stream: turbo_stream.update("flash", partial: "layouts/flash", locals: { messages: { alert: refusal } }), status: :conflict
          end
        end
        format.html { redirect_back_or_to fallback, alert: (refusal unless done), status: :see_other }
      end
    end
end
