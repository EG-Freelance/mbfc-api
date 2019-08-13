class CreateSources < ActiveRecord::Migration
  def change
    create_table :sources do |t|
    	t.string :name
    	t.string :display_name
    	t.string :url
    	t.string :bias
    	t.string :accuracy
    	t.string :mbfc_url
    	t.date :verified, :default => Date.new(2019,1,11)

      t.timestamps null: false
    end
  end
end
