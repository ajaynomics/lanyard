class CreateAhoyVisitsAndEvents < ActiveRecord::Migration[8.2]
  def change
    create_table :ahoy_visits do |t|
      t.string :visit_token
      t.string :visitor_token
      t.references :user, foreign_key: { on_delete: :nullify }
      t.string :ip
      t.text :user_agent
      t.text :referrer
      t.string :referring_domain
      t.text :landing_page
      t.string :browser
      t.string :os
      t.string :device_type
      t.string :utm_source
      t.string :utm_medium
      t.string :utm_term
      t.string :utm_content
      t.string :utm_campaign
      t.datetime :started_at
    end
    add_index :ahoy_visits, :visit_token, unique: true
    add_index :ahoy_visits, %i[ visitor_token started_at ]

    create_table :ahoy_events do |t|
      t.references :visit, foreign_key: { to_table: :ahoy_visits, on_delete: :nullify }
      t.references :user, foreign_key: { on_delete: :nullify }
      t.string :name
      t.json :properties
      t.datetime :time
    end
    add_index :ahoy_events, %i[ name time ]
  end
end
