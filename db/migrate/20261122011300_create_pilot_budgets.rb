class CreatePilotBudgets < ActiveRecord::Migration[8.2]
  def change
    create_table :agent_pilot_budgets do |t|
      t.references :agent, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false
      t.date :month, null: false
      t.boolean :blocked, null: false, default: false
      t.timestamps

      t.index [ :agent_id, :kind, :month ], unique: true
      t.check_constraint "kind IN ('voice', 'computer')", name: "pilot_budget_kind"
    end

    create_table :pilot_budget_reservations do |t|
      t.references :pilot_budget, null: false, index: false, foreign_key: { to_table: :agent_pilot_budgets, on_delete: :cascade }
      t.string :request_key, null: false
      t.integer :maximum_cents, null: false
      t.integer :actual_cents
      t.timestamps

      t.index [ :pilot_budget_id, :request_key ], unique: true
      t.check_constraint "maximum_cents BETWEEN 1 AND 5000 AND (actual_cents IS NULL OR actual_cents >= 0)", name: "pilot_budget_amounts"
    end

    create_table :pilot_budget_alerts do |t|
      t.references :pilot_budget, null: false, index: false, foreign_key: { to_table: :agent_pilot_budgets, on_delete: :cascade }
      t.integer :threshold, null: false
      t.timestamps

      t.index [ :pilot_budget_id, :threshold ], unique: true
      t.check_constraint "threshold IN (50, 80)", name: "pilot_budget_alert_threshold"
    end
  end
end
