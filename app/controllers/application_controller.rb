class ApplicationController < ActionController::API
	def get_data
    sources = Source.all.sort_by(&:name).map { |s| {:name => s.name, :display_name => s.display_name, :url => s.url, :bias => s.bias, :accuracy => s.accuracy, :mbfc_url => s.mbfc_url, :verified_date => s.verified } }
    payload = { :results => sources.count, :sources => sources }
    render :json => payload
  end

  def get_data_for_plugin
    sources = Source.all.sort_by(&:name)
    sources_hash = {}
    sources.each do |source|
      if source.url[/facebook/i]
        # do not include any sources that use FB as their homepage for plugin -- will give incorrectly generalized results
        next
      end
      if source.name == "borowitz report"
        # special case for borowitz report
        key = source.url
      else
        key = source.url.match(/(?:https?\:\/\/)?(?:www\.)?([A-Za-z0-9\.\-]*)\/?/)[1]
      end
      sources_hash[key] = { 'bias' => source.bias, 'accuracy' => source.accuracy, 'href' => source.mbfc_url }
    end
    render :json => sources_hash
  end
end
