require 'json'
require 'turbotlib'
require 'nokogiri'
require 'zip'
require 'httparty'

class HTTParty::Basement; default_timeout 120; end

class CompaniesHouse

  ROOT_DOMAIN = "http://download.companieshouse.gov.uk"

  def self.run(num)
    page = Nokogiri::HTML(open("#{ROOT_DOMAIN}/en_output.html"))
    link = page.css('ul').first.css('li')[num].css('a').first
    file = CompaniesHouse.new(link[:href])
    file.process
  end

  def initialize(filename)
    @filename = filename
    @url = "#{ROOT_DOMAIN}/#{filename}"
    @downloaded_at = DateTime.now
  end

  def process
    download_file
    read_zip
  end

  def download_file
    Turbotlib.log("Downloading #{@filename}")
    File.open("/tmp/#{@filename}", "wb") do |f|
      f.write open(@url).read
    end
  end

  def read_zip
    Zip::File.open("/tmp/#{@filename}") do |zip_file|
      zip_file.each do |entry|
        Turbotlib.log("Extracting #{entry.name}")
        csv = "/tmp/#{entry.name}"
        entry.extract(csv)
        Turbotlib.log("Parsing #{entry.name}")
        parse_csv(csv)
      end
    end
  end

  def parse_csv(filename)
    CSV.foreach(filename, headers: true) do |row|
      if row["RegAddress.PostCode"]
        parse_address(row)
      end
    end
  end

  def parse_address(row)
    address = [
      row["RegAddress.AddressLine1"],
      row["RegAddress.AddressLine2"],
      row["RegAddress.PostTown"],
      row["RegAddress.PostCode"]
    ].join(", ")
    response = request_with_retries("http://sorting-office.openaddressesuk.org/address", address)
    unless response.nil? || response["error"] || response["street"].nil? || response["town"].nil? || response["paon"].nil?
      json = build_address(response, valid_at_date(row))
      puts JSON.dump(json)
    end
  end

  def build_address(response, date)
    {
      saon: response["saon"],
      paon: response["paon"],
      street: response["street"]["name"],
      locality: response["locality"].nil? ? nil : response["locality"]["name"],
      town: response["town"]["name"],
      postcode: response["postcode"]["name"],
      valid_at: date,
      provenance: build_provenance(response),
    }
  end

  def valid_at_date(row)
    [
      row["IncorporationDate"],
      row["Returns.LastMadeUpDate"],
      row["Accounts.LastMadeUpDate"]
    ].map! { |d| DateTime.parse(d) rescue nil }.reject {|d| d.nil?}.sort.last
  end

  def build_provenance(response)
    prov = {
      activity: {
        executed_at: DateTime.now,
        processing_scripts: "http://github.com/oa-bots/companies_house",
        derived_from: [
          {
            type: "Source",
            urls: [@url],
            downloaded_at: @downloaded_at,
            processing_script: "https://github.com/oa-bots/companies_house/tree/#{current_sha}/scraper.rb"
          }
        ]
      }
    }
    [:street, :locality, :town, :postcode].each do |part|
      unless response[part.to_s].nil?
        prov[:activity][:derived_from] << {
          type: "Source",
          urls: [
            response[part.to_s]["url"]
          ],
          downloaded_at: DateTime.now,
          processing_script: "https://github.com/oa-bots/companies_house/tree/#{current_sha}/scraper.rb"
        }
      end
    end
    prov
  end

  def request_with_retries(url, address)
    tries = 0
    begin
      response = HTTParty.post(url, body: {address: address})
      raise StandardError if ![200,400].include?(response.code)
      JSON.parse(response.body)
    rescue
      tries += 1
      Turbotlib.log("Address #{address} caused explosion")
      retry_secs = 5 * tries
      Turbotlib.log("Retrying in #{retry_secs} seconds.")
      if tries < 5
        sleep(retry_secs)
        retry
      else
        Turbotlib.log("Giving up")
      end
    end
  end

  def current_sha
    @current_sha ||= `git rev-parse HEAD`.strip rescue nil
  end

end
