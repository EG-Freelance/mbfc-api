require 'csv'

class Source < ActiveRecord::Base
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
end
