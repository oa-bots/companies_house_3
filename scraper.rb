$:.unshift File.dirname(__FILE__)

require 'companies_house'

Turbotlib.log("Starting run...")

num = (ENV['NUMBER'] || 0).to_i

CompaniesHouse.run(num)
