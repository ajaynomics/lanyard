# A field Rails knows is wrong says so where it is (shadcn: FormMessage): it is
# marked invalid, and its message follows it, tied to it for screen readers.
# A form's summary at the top still lists them all. Rails' default wraps the
# field in a div, which would break the form's grid.
Rails.application.config.action_view.field_error_proc = proc do |html_tag, instance|
  field = Nokogiri::HTML5.fragment(html_tag).element_children.first
  next html_tag unless field && field.name.in?(%w[ input textarea select ]) && field["type"] != "hidden"

  method = instance.instance_variable_get(:@method_name)
  messages = instance.object.errors.full_messages_for(method).to_sentence
  id = "#{field['id'] || "#{instance.object_name}_#{method}"}_error"
  field["aria-invalid"] = "true"
  field["aria-describedby"] = [ field["aria-describedby"], id ].compact.join(" ")
  "#{field.to_html}<p class=\"field__error\" id=\"#{id}\">#{ERB::Util.html_escape(messages)}</p>".html_safe
end
