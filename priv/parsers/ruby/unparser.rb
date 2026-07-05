#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'parser/current'
require 'unparser'
require 'json'

module Metastatic
  # Ruby AST unparser that converts JSON AST back to Ruby source code
  class RubyUnparser
    # Unparse JSON AST back to Ruby source code
    #
    # @param ast_json [String] JSON-serialized AST
    # @return [Hash] Result with source code or error
    def self.unparse(ast_json)
      data = JSON.parse(ast_json, symbolize_names: true)
      ast = deserialize_node(data[:ast])
      source = Unparser.unparse(ast)
      
      {
        status: 'ok',
        source: source
      }
    rescue JSON::ParserError => e
      {
        status: 'error',
        error: "JSON parse error: #{e.message}"
      }
    rescue StandardError => e
      {
        status: 'error',
        error: "#{e.class}: #{e.message}",
        backtrace: e.backtrace.first(5)
      }
    end

    # Deserialize a JSON structure back to Parser::AST::Node
    #
    # @param data [Hash, nil, Object] Serialized node data
    # @return [Parser::AST::Node, nil, Object] Deserialized AST node
    def self.deserialize_node(data)
      return nil if data.nil?
      
      # Handle primitives (literals)
      return data unless data.is_a?(Hash)
      
      # If it doesn't have a type, it's likely metadata or a literal value
      return data unless data[:type]

      type = data[:type].to_sym
      children = data[:children].map { |child| deserialize_node(child) }
      
      Parser::AST::Node.new(type, children)
    end
  end
end

# CLI interface: read JSON from STDIN, write source to STDOUT
if __FILE__ == $PROGRAM_NAME
  ast_json = $stdin.read
  result = Metastatic::RubyUnparser.unparse(ast_json)
  
  if result[:status] == 'ok'
    puts result[:source]
  else
    warn "Error: #{result[:error]}"
    warn result[:backtrace].join("\n") if result[:backtrace]
    exit 1
  end
end
