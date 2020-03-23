namespace :automate do
  task :get_new => :environment do
    recent = Source.all.map(&:updated_at).max.to_date
    Source.update_sources(recent)
  end
end