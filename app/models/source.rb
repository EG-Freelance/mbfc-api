require 'csv'

class Source < ActiveRecord::Base
  scope :vhf, -> { where(accuracy: "very high") }
  scope :hf, -> { where(accuracy: "high") }
  scope :mostf, -> { where(accuracy: "mostly factual") }
  scope :mixedf, -> { where(accuracy: "mixed") }
  scope :lowf, -> { where(accuracy: "low") }
  scope :vlf, -> { where(accuracy: "very low") }
  scope :rb, -> { where(bias: "right") }
  scope :rcb, -> { where(bias: "right-center") }
  scope :leastb, -> { where(bias: "least biased") }
  scope :lcb, -> { where(bias: "left-center") }
  scope :lb, -> { where(bias: "left") }
  scope :ps, -> { where(bias: "pro-science") }
  scope :consp, -> { where(bias: "conspiracy/pseudoscience") }
  scope :q, -> { where(bias: "questionable") }
  scope :no_bias, -> { where(bias: 'unlisted') }
  scope :no_acc, -> { where(accuracy: 'unlisted') }
  scope :no_source, -> { where(url: 'unlisted') }
  scope :bad_acc, -> { where(accuracy: 'not parsed') }
  scope :bad_bias, -> { where(bias: 'not parsed') }

  def self.upload_sources(filename, verified_date)
    CSV.read(filename, :headers => true).each do |row|
      source = self.find_by(:name => row["Source"].try(:downcase))
      if source
        unless self.exists?(:name => row["Source"].try(:downcase), :url => row["MBFC Source Link"].try(:downcase), :bias => row["Bias"].try(:downcase), :accuracy => row["Reporting"].try(:downcase), :mbfc_url => row["MBFC link"].try(:downcase))
          source.update(:display_name => row["Source"], :url => row["MBFC Source Link"].try(:downcase), :bias => row["Bias"].try(:downcase), :accuracy => row["Reporting"].try(:downcase), :mbfc_url => row["MBFC link"].try(:downcase), :verified => DateTime.strptime(verified_date, "%Y-%m-%d").to_date)
        end
      else
        Source.create(:name => row["Source"].try(:downcase), :display_name => row["Source"], :url => row["MBFC Source Link"].try(:downcase), :bias => row["Bias"].try(:downcase), :accuracy => row["Reporting"].try(:downcase), :mbfc_url => row["MBFC link"].try(:downcase), :verified => DateTime.strptime(verified_date, "%Y-%m-%d").to_date)
      end
    end
  end

  def self.get_sources(type)
    # for type, use the URL param (i.e. mediabiasfactcheck.com/#{type}/)
    agent = Mechanize.new
    failures = []

    page = agent.get("https://mediabiasfactcheck.com/#{type}/")
    entries = page.at('#mbfc-table').css('td a')
    entries.each do |entry|
      mbfc_url = entry.attributes['href'].value
      begin
        acc, bias, source, s_name = Source.get_metrics({ :mbfc_url => mbfc_url }, true)
      rescue
        puts "MBFC link inactive or data are malformed -- #{mbfc_url}"
        failures << mbfc_url
        next
      end
      Source.where(mbfc_url: mbfc_url).first_or_create.update(accuracy: acc, bias: bias, url: source, name: s_name.downcase, display_name: s_name, verified: Date.today)
    end
    puts failures
  end

  def self.update_sources(date)
    # define method to extract new info
    agent = Mechanize.new

    source_hashes = []
    new_source_hashes = []


    ##### RE-EVALUATIONS ######
    page = agent.get("https://mediabiasfactcheck.com/re-evaluated-sources")
    raw_els = page.search('p').select { |p| p.text[/\(\d{1,2}\/\d{1,2}\/\d{4}\)/] }
    els = raw_els.map { |el| el.children }.flatten

    source_arrays = els.delete_if { |el| el.text == "\n" }.split { |el| el.name == "br" }

    source_arrays.each do |sa|
      source_hashes << { 
        :mbfc_url => sa[0].attributes['href'].value, 
        :name => sa[0].text, 
        :updated => DateTime.strptime(sa[1].text.match(/(\d{1,2}\/\d{1,2}\/\d{4})/)[1], "%m/%d/%Y")
      }
    end
    ###########################

    ##### RECENTLY ADDED #####
    # (uses mechanize page from re-evaluations)
    raw_els = page.css('.recently')[0].children
    els = raw_els.css('li').to_a
    els.each do |el|
      src = el.css('a')[0].attributes
      new_source_hashes << {
        :mbfc_url => src['href'].value,
        :name => src['title'].value,
        :updated => DateTime.strptime(el.css('span')[0].text, "posted on %B %d, %Y")
      }
    end
    ###########################

    ##### CORRECTIONS #####
    page = agent.get("https://mediabiasfactcheck.com/changes-corrections/")
    els = page.css('.entry li')
    els = els.select { |el| el.text.match(/\d{1,2}\/\d{1,2}\/\d{4}/) }

    els.each do |el|
      source_hashes << {
        :mbfc_url => el.children.css('a')[0].attributes['href'].value,
        :updated => DateTime.strptime(el.children[0].text.match(/(\d{1,2}\/\d{1,2}\/\d{4})/)[1], "%m/%d/%Y")
      }
    end
    ########################

    # remove duplicates (by mbfc_url), prioritizing most recent
    source_hashes = source_hashes.sort { |sh| -sh[:updated].to_i }.uniq { |sh| sh[:mbfc_url] }
    
    updates = source_hashes.select { |sh| sh[:updated] >= date }
    new_entries = new_source_hashes.select { |sh| sh[:updated] >= date }

    updates.each do |update|
      puts "Update #{update[:mbfc_url]}"
      source = Source.find_by(mbfc_url: update[:mbfc_url])
      if !source
        puts "couldn't find source for #{update[:mbfc_url]; moving to new_entries }"
        new_entries << update
        next
      end

      acc, bias = Source.get_metrics(update, false)
      source.update(bias: bias, accuracy: acc, verified: Date.today.strftime("%Y-%m-%d"))
    end

    new_entries.each do |new_entry|
      puts "New #{new_entry[:mbfc_url]}"
      acc, bias, source, s_name = Source.get_metrics(new_entry, true)
      Source.create(name: s_name.downcase, display_name: s_name, url: source, bias: bias, accuracy: acc, mbfc_url: new_entry[:mbfc_url], verified: Date.today.strftime("%Y-%d-%m"))
    end
  end

  def self.update_or_create_entries(mbfc_links)
    agent = Mechanize.new

    mbfc_links.each do |link|
      puts "Getting info for #{link}"
      page = agent.get(link)
      entry = { :mbfc_url => link, :updated => Date.today } # updated in this instance just says when we acquired the data
      acc, bias, source, s_name = Source.get_metrics(entry, true)

      Source.where(mbfc_url: entry[:mbfc_url]).first_or_create.update(name: s_name.downcase, display_name: s_name, url: source, bias: bias, accuracy: acc, verified: Date.today.strftime("%Y-%d-%m"))
    end  
  end

  def self.collect_missing
    # collect missing entries from re-evaluations (shouldn't need to be run often)
    agent = Mechanize.new

    source_hashes = []
    new_entries = []

    ##### RE-EVALUATIONS ######
    page = agent.get("https://mediabiasfactcheck.com/re-evaluated-sources")
    raw_els = page.search('p').select { |p| p.text[/\(\d{1,2}\/\d{1,2}\/\d{4}\)/] }
    els = raw_els.map { |el| el.children }.flatten

    source_arrays = els.delete_if { |el| el.text == "\n" }.split { |el| el.name == "br" }

    source_arrays.each do |sa|
      source_hashes << { 
        :mbfc_url => sa[0].attributes['href'].value, 
        :name => sa[0].text, 
        :updated => DateTime.strptime(sa[1].text.match(/(\d{1,2}\/\d{1,2}\/\d{4})/)[1], "%m/%d/%Y")
      }
    end

    source_hashes.each do |sh|
      puts "get info for #{sh[:mbfc_url]}"
      source = Source.find_by(mbfc_url: sh[:mbfc_url])
      if !source
        puts "couldn't find source for #{sh[:mbfc_url]}; moving to new_entries"
        new_entries << sh[:mbfc_url]
      end
    end

    return new_entries
  end

  ##### HELPER METHODS #####
  def self.get_metrics(info_hash, create_new)
    agent = Mechanize.new
    page = agent.get(info_hash[:mbfc_url])
    metric_els = page.css('img').select { |i| !i.attributes['data-attachment-id'].nil? }
    acc = nil
    bias = nil
    source = nil
    s_name = page.at('.page-title').text

    metric_els.each do |me|
      txt = me.attributes['data-image-title'].text

      case
      when txt["VeryLowFactual"]
        acc = "very low"
      when txt["LowFactual"]
        acc = "low"
      when txt["MixedFactual"]
        acc = "mixed"
      when txt["MostlyFactual"]
        acc = "mostly factual"
      when txt["HighFactual"]
        acc = "high"
      when txt["VeryHighFactual"]
        acc = "very high"
      when txt["extremeright"]
        bias = "questionable"
      when txt["extremeleft"]
        bias = "questionable"
      when txt["leftcenter"] # order matters for leftcenter/left and rightcenter/right
        bias = "left-center"
      when txt["rightcenter"]
        bias = "right-center"
      when txt.match(/\Aleft/)
        bias = "left"
      when txt.match(/\Aright/)
        bias = "right"
      when txt["leastbiased"]
        bias = "least biased"
      when txt["Proscience"]
        bias = "pro-science"
      when txt.match(/\Acon/) || txt.match(/\Apseudo/)
        bias = "conspiracy/pseudoscience"
      when txt["satirelabel"]
        bias = "satire"
        acc = "satire"
      else
        if !acc
          acc = "not parsed"
        elsif !bias
          bias = "not parsed"
        end
        # send notification email?
      end

      # use secondary method to extract accuracy if not already set
      if !acc
        el = page.css('p').find { |p| p.text.match(/\AFactual/) }
        if el
          acc = el.at('span').text.gsub("\n", "").downcase
        end
      end
      acc = "unlisted" if !acc
      bias = "unlisted" if !bias
    end

    if create_new
      begin
        source_el = page.css('p').find { |t| t.text.match(/\ASource:/) && t.css('a') && !t.children[1].try(:attributes).try(:[], 'href').nil? }
        source = source_el.css('a')[0].attributes['href'].value
      rescue
        source = "unlisted"
      end
    end

    return acc, bias, source, s_name
  end
  ##########################

  #### NOTES: ####
  # sources listed improperly or differently:  https://genesiustimes.com, https://www.cracked.com, http://viralactions.com, http://www.the-postillion.com
  # Borowitz Report is a subsection of The New Yorker, so can't list the same way as others (otherwise, plugins will list The New Yorker as satire)
  # types = ["left", "leftcenter", "center", "right-center", "right", "pro-science"]
end