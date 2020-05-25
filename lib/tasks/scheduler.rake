namespace :automate do
  task :get_new => :environment do
    recent = Source.all.map(&:updated_at).max.to_date
    Source.update_sources(recent)
  end

  task :scrub_all => environment do
    Source.scrub_all_listings
  end
end