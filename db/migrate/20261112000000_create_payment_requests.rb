# A payment an agent asks for with a one-time card from the person's Link
# wallet (PaymentRequest, docs/payments.md), one per call; and each person's
# Link sign-in. Neither ever holds a card's number.
class CreatePaymentRequests < ActiveRecord::Migration[8.2]
  def change
    add_column :users, :link_session, :text

    create_table :payment_requests do |t|
      t.references :invocation, null: false, foreign_key: true, index: { unique: true }
      t.string :state, null: false, default: "requested"
      t.integer :amount, null: false
      t.string :currency, null: false
      t.string :payee, null: false
      t.string :checkout_url, null: false
      t.text :reason, null: false
      t.string :link_id
      t.string :approval_url
      t.datetime :expires_at
      t.string :card_brand
      t.string :card_last4
      t.datetime :card_valid_until
      t.datetime :filled_at
      t.string :decided_by
      t.string :failure
      # When its job next asks Link, so a lost job is noticed (PaymentRequest.sweep).
      t.datetime :next_ask_at, index: true
      t.timestamps
    end
  end
end
