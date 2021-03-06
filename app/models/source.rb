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
  scope :bad_parse, -> { where(accuracy: 'bad parse') }

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
      txt_raw = sa.map(&:text).join("").partition(/\(\d{1,2}\/\d{1,2}\/\d{4}\)/)
      source_hashes << { 
        :mbfc_url => sa[0].attributes['href'].value, 
        # :name => sa[0].text, 
        # :updated => DateTime.strptime(sa[1].text.match(/(\d{1,2}\/\d{1,2}\/\d{4})/)[1], "%m/%d/%Y")
        :name => txt_raw[0].strip,
        :updated => DateTime.strptime(txt_raw[1].match(/(\d{1,2}\/\d{1,2}\/\d{4})/)[1], "%m/%d/%Y")
      }
    end
    ###########################

    ##### RECENTLY ADDED #####
    # (uses mechanize page from re-evaluations)
    raw_els = page.css('.srpw-li')
    els = raw_els.css('li').to_a
    els.each do |el|
      src = el.css('a')[0].attributes
      new_source_hashes << {
        :mbfc_url => src['href'].value,
        :name => el.css('a')[0].text,
        :updated => DateTime.strptime(el.css('.srpw-time')[0].text, "%B %d, %Y")
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
        puts "couldn't find source for #{update[:mbfc_url]}; moving to new_entries"
        new_entries << update
        next
      end

      acc, bias = Source.get_metrics(update, false)
      source.update(bias: bias, accuracy: acc, verified: Date.today.strftime("%Y-%m-%d"))
    end

    new_entries.each do |new_entry|
      puts "New #{new_entry[:mbfc_url]}"
      acc, bias, source, s_name = Source.get_metrics(new_entry, true)
      unless acc == "unlisted" && bias == "unlisted" && source == "unlisted"
        # If the listing doesn't point anywhere real, don't do anything with it
        Source.create(name: s_name.downcase, display_name: s_name, url: source, bias: bias, accuracy: acc, mbfc_url: new_entry[:mbfc_url], verified: Date.today.strftime("%Y-%d-%m"))
      end
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
    # info_hash = { 'mbfc_url', 'name', 'updated' }
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
      when txt.match(/VeryLow/i)
        acc = "very low"
      when txt.match(/Low/i)
        acc = "low"
      when txt.match(/Mixed/i)
        acc = "mixed"
      when txt.match(/MostlyFactual/i)
        acc = "mostly factual"
      when txt.match(/VeryHigh/i)
        acc = "very high"
      when txt.match(/High/i)
        acc = "high"
      when txt.match(/extremeright/i)
        bias = "questionable"
      when txt.match(/extremeleft/i)
        bias = "questionable"
      when txt.match(/leftcenter/i) # order matters for leftcenter/left and rightcenter/right
        bias = "left-center"
      when txt.match(/rightcenter/i)
        bias = "right-center"
      when txt.match(/\Aleft/i)
        bias = "left"
      when txt.match(/\Aright/i)
        bias = "right"
      when txt.match(/leastbiased/i)
        bias = "least biased"
      when txt.match(/Proscience/i)
        bias = "pro-science"
      when txt.match(/\Acon/) || txt.match(/\Apseudo/)
        bias = "conspiracy/pseudoscience"
      when txt.match(/satirelabel/i)
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
    end

    # use secondary method to extract accuracy if not already set
    if !acc
      el = page.css('p').find { |p| p.text.match(/\AFactual/) }
      if el
        # recursively dig to get base level node matching expectation
        while el.children.count > 0
          el = el.children.find { |c| c.text.match(/high|low|mixed|mostly/i) }
        end

        acc = el.text.gsub(/\p{Space}/," ").gsub("-", " ").downcase.strip
        if !["very high", "high", "mostly factual", "mixed", "low", "very low", "unlisted", "satire"].include?(acc)
          acc = "bad parse"
        end
      end
    end

    # use secondary method to extract bias if not already set
    if !bias
      # try to get .entry-title first, then .entry-header h1
      el = page.at('.entry-title')
      if !el
        el = page.css('h1').find { |c| c.text.match(/\A[A-Z\s\-]{5,100}\z/) }
      end
      if !el
        el = page.css('h2').find { |c| c.text.match(/\A[A-Z\s\-]{5,100}\z/) }
      end
      if el
        case
        when el.text.match(/questionable/i)
          bias = "questionable"
        when el.text.match(/least biased/i)
          bias = "least biased"
        when el.text.match(/mixed/i)
          bias = "mixed"
        else
          bias = "not parsed"
        end
      end      
    end
    acc = "unlisted" if !acc
    bias = "unlisted" if !bias

    if create_new
      begin
        source_el_1 = page.css('a').find { |t| t.text.strip.gsub(/\p{Space}/,"") == t.try(:attributes).try(:[], 'href').try(:value) }
        if !source_el_1
          source_el_2 = page.css('p').find { |t| t.text.match(/\ASources?:/) && t.css('a') && !t.children[1].try(:attributes).try(:[], 'href').nil? }
        end
        if !source_el_2
          source_el_2 = page.css('p').find { |t| t.text.match(/\ANotes?:/) && t.css('a') && !t.children[1].try(:attributes).try(:[], 'href').nil? }
        end
        if source_el_1
          source = source_el_1.attributes['href'].value
        elsif source_el_2
          source = source_el_2.at('a').attributes['href'].value
        else
          source = "unlisted"
        end
      rescue
        source = "unlisted"
      end
    end

    return acc, bias, source, s_name
  end


  def self.scrub_all_listings
    agent = Mechanize.new
    page = agent.get("https://raw.githubusercontent.com/drmikecrowe/mbfcext/main/docs/v3/combined.json")

    json = eval(page.body)
    # :b => bias
    # :d => base source URL
    # :f => ASCII name
    # :n => Name
    # :r => Reliability (bias)
    # :u => MBFC URL
    # :P => ?
    # :c => ?  Traffic?
    # :a => ?

    sources = json[:sources]

    sources.each do |source, values|
      acc_raw = values[:r]
      bias_raw = values[:b]
      mbfc_url = values[:u]
      url = values[:d]
      display_name = values[:n]
      name_lower = display_name.downcase

      # ignore entries that don't show an internal page
      if !mbfc_url["mediabiasfactcheck.com"]
        next
      end

      case acc_raw
      when "VL"
        acc = "very low"
      when "L"
        acc = "low"
      when "M"
        acc = "mixed"
      when "MF"
        acc = "mostly factual"
      when "H"
        acc = "high"
      when "VH"
        acc = "very high"
      else
        acc = ""
      end

      case bias_raw
      when "L"
        bias = "left"
      when "LC"
        bias = "left-center"
      when "C"
        bias = "least biased"
      when "RC"
        bias = "right-center"
      when "R"
        bias = "right"
      when "FN"
        bias = "fake"
      when "CP"
        bias = "conspiracy/pseudoscience"
      when "PS"
        bias = "pro-science"
      when "S"
        bias = "satire"
      else
        bias = ""
      end

      Source.where(mbfc_url: mbfc_url).first_or_create.update(name: name_lower, display_name: display_name, url: url, bias: bias, accuracy: acc, verified: Date.today.strftime("%Y-%m-%d"))
      # s = Source.find_by(mbfc_url: mbfc_url)
      # if s
      #   s.update(name: name_lower, display_name: display_name, url: url, bias: bias, accuracy: acc, verified: Date.today.strftime("%Y-%m-%d"))
      # else
      #   Source.create(name: name_lower, display_name: display_name, url: url, bias: bias, accuracy: acc, verified: Date.today.strftime("%Y-%m-%d", mbfc_url: mbfc_url)
      # end
    end
  end

  def self.scrub_all_listings_legacy
    # use MBFC's filtered search page to correct any missed updates or miscoded metrics
    # only works for bias, accuracy, and MBFC URL
    agent = Mechanize.new
    page = agent.get('https://mediabiasfactcheck.com/filtered-search/')

    data_script = page.css('script').find { |s| s.text["getData()"] }.text.gsub(/\r\n/, "").gsub(/\t/, "")

    sources = data_script.match(/current_json\s?=\s?(\{.*?);/)[1]

    json = eval(sources)
    # :b => bias
    # :d => base source URL
    # :h => full source URL
    # :L => references
    # :n => display name
    # :r => accuracy
    # :u => MBFC url
    # :c => country

    json.each do |source, values|
      # 2020-05-24 -- verified that all current sources and all json sources end with '/'
      puts "Saving information for #{source}"

      if values[:u][-1].nil?
        puts "Not saving for self"
        next
      end

      # need to fix entries that are broken with double HTTPs
      url = values[:h].match(/((?:https?:\/\/)(?!https?:\/\/).*)/)[1]

      s = Source.find_by(mbfc_url: values[:u])
      if s
        s.update(name: values[:n].downcase, display_name: values[:n], url: url, bias: values[:b].downcase.gsub(" sources", "").gsub("conspiracy-pseudoscience", "conspiracy/pseudoscience"), accuracy: values[:r].downcase, verified: Date.today.strftime("%Y-%m-%d"))
      else
        Source.create(name: values[:n].downcase, display_name: values[:n], url: url, bias: values[:b].downcase.gsub(" sources", "").gsub("conspiracy-pseudoscience", "conspiracy/pseudoscience"), accuracy: values[:r].downcase, verified: Date.today.strftime("%Y-%m-%d"), mbfc_url: values[:u])
      end
    end
  end
  ##########################

  #### NOTES: ####
  # sources listed improperly or differently:  https://genesiustimes.com, https://www.cracked.com, http://viralactions.com, http://www.the-postillion.com
  # Borowitz Report is a subsection of The New Yorker, so can't list the same way as others (otherwise, plugins will list The New Yorker as satire)
  # types = ["left", "leftcenter", "center", "right-center", "right", "pro-science"]
  # entries to hand-edit source urls:  CNN, Yahoo, Monmouth
  # duplicate bbc to include bbc.co.uk url as well as .com
end