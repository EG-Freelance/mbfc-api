class ApplicationController < ActionController::API
	def get_data
    sources = Source.all.sort_by(&:name).map { |s| {:name => s.name, :display_name => s.display_name, :url => s.url, :bias => s.bias, :accuracy => s.accuracy, :mbfc_url => s.mbfc_url, :verified_date => s.verified } }
    payload = { :results => sources.count, :sources => sources }
    render :json => payload
  end
end
