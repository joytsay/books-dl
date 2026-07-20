require 'rubygems'
require 'bundler'
require 'json'
require 'digest'
require 'openssl'
require 'fileutils'
require 'io/console'
require 'ostruct'
require 'securerandom'
require 'tmpdir'
require 'uri'

Bundler.require(:default)

module BooksDL; end

Dir[File.join(__dir__, 'books_dl', '**', '*.rb')].each(&method(:require))
