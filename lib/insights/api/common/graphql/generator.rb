require "erb"

module Insights
  module API
    module Common
      module GraphQL
        module Generator
          PARAMETERS_PATH = "/components/parameters".freeze
          SCHEMAS_PATH = "/components/schemas".freeze

          def self.openapi_schema(openapi_doc, klass_name)
            schemas = openapi_doc.content.dig(*path_parts(SCHEMAS_PATH))
            [klass_name, "#{klass_name}Out"].each do |name|
              schema = schemas[name]
              return [name, schema] if schema
            end
          end

          def self.path_parts(openapi_path)
            openapi_path.split("/")[1..-1]
          end

          def self.template_file_by(type, root_dir = __dir__)
            Pathname.new(root_dir).join(File.expand_path("templates", root_dir), "#{type}.erb")
          end

          def self.root_dir
            Rails.root
          end

          def self.app_name
            Rails.application.class.module_parent.name.underscore
          end

          def self.pluggable_template_file_by(type)
            templates_relative_path = "lib/#{app_name}/api/graphql/templates"
            template_path = File.expand_path(templates_relative_path, root_dir)
            Pathname.new(root_dir).join(template_path, "#{type}.erb")
          end

          def self.template_path_by(type)
            template_path_pluggable = pluggable_template_file_by(type)
            template_path_default   = template_file_by(type)
            template_path_pluggable.exist? ? template_path_pluggable : template_path_default
          end

          def self.template(type)
            File.read(template_path_by(type))
          end

          def self.graphql_type(property_name, property_format, property_type)
            return "!types.ID" if property_name == "id"

            case property_type
            when "string"
              property_format == "date-time" ? "::Insights::API::Common::GraphQL::Types::DateTime" : "types.String"
            when "number"
              "types.Float"
            when "boolean"
              "types.Boolean"
            when "integer"
              "::Insights::API::Common::GraphQL::Types::BigInt"
            end
          end

          def self.resource_associations(openapi_content, collection)
            collection_is_associated = openapi_content["paths"].keys.any? do |path|
              path.match?("^/[^/]*/{[[a-z]*_]*id}/#{collection}$") &&
                openapi_content.dig("paths", path, "get").present?
            end
            collection_associations = []
            openapi_content["paths"].keys.each do |path|
              subcollection_match = path.match("^/#{collection}/{[[a-z]*_]*id}/([^/]*)$")
              next unless subcollection_match

              subcollection = subcollection_match[1]
              next unless openapi_content["paths"].keys.any? do |subcollection_path|
                subcollection_path.match?("^/#{subcollection}/{[[a-z]*_]*id}$") &&
                openapi_content.dig("paths", subcollection_path, "get").present?
              end

              collection_associations << subcollection
            end
            [collection_is_associated ? true : false, collection_associations.sort]
          end

          def self.collection_field_resolvers(schema_overlay, collection)
            field_resolvers = {}
            schema_overlay.keys.each do |collection_regex|
              next unless collection.match(collection_regex)

              field_resolvers.merge!(schema_overlay.fetch_path(collection_regex, "field_resolvers") || {})
            end
            field_resolvers
          end

          def self.collection_schema_overlay(schema_overlay, collection)
            schema_overlay.keys.each_with_object({}) do |collection_regex, collection_schema_overlay|
              next unless collection.match?(collection_regex)

              collection_schema_overlay.merge!(schema_overlay[collection_regex] || {})
            end
          end

          def self.init_schema(request, schema_overlay = {})
            base_init_schema(request, { :use_pagination_v2 => false }, schema_overlay)
          end

          def self.init_schema_v2(request, schema_overlay = {})
            base_init_schema(request, { :use_pagination_v2 => true }, schema_overlay)
          end

          def self.base_init_schema(request, graphql_options, schema_overlay = {})
            api_version       = ::Insights::API::Common::GraphQL.version(request)
            version_namespace = "V#{api_version.tr('.', 'x')}"
            openapi_doc       = ::Insights::API::Common::OpenApi::Docs.instance[api_version]
            openapi_content   = openapi_doc.content

            graphql_namespace = if ::Insights::API::Common::GraphQL::Api.const_defined?(version_namespace, false)
                                  ::Insights::API::Common::GraphQL::Api.const_get(version_namespace)
                                else
                                  ::Insights::API::Common::GraphQL::Api.const_set(version_namespace, Module.new)
                                end

            return graphql_namespace.const_get("Schema") if graphql_namespace.const_defined?("Schema", false)

            resources = openapi_content["paths"].keys.sort
            collections = []
            resources.each do |resource|
              next unless openapi_content.dig("paths", resource, "get") # we only care for queries

              rmatch = resource.match("^/(.*/)?([^/]*)/{[[a-z]*_]*id}$")
              next unless rmatch

              collection = rmatch[2]
              klass_name = collection.camelize.singularize
              next if graphql_namespace.const_defined?("#{klass_name}Type", false)

              _schema_name, this_schema = openapi_schema(openapi_doc, klass_name)
              next if this_schema.nil? || this_schema["type"] != "object" || this_schema["properties"].nil?

              collections << collection

              model_class = klass_name.constantize
              model_encrypted_columns_set = (model_class.try(:encrypted_columns) || []).to_set

              model_properties = []
              properties = this_schema["properties"]
              properties.keys.sort.each do |property_name|
                next if model_encrypted_columns_set.include?(property_name)

                property_schema = properties[property_name]
                property_schema = openapi_content.dig(*path_parts(property_schema["$ref"])) if property_schema["$ref"]
                property_format = property_schema["format"] || ""
                property_type   = property_schema["type"]
                description     = property_schema["description"]

                property_graphql_type = graphql_type(property_name, property_format, property_type)
                model_properties << [property_name, property_graphql_type, description] if property_graphql_type
              end

              field_resolvers = collection_field_resolvers(schema_overlay, klass_name)
              model_is_associated, model_associations = resource_associations(openapi_content, collection)

              graphql_model_type_template = ERB.new(template("model_type"), nil, '<>').result(binding)
              graphql_namespace.module_eval(graphql_model_type_template)
            end

            graphql_query_type_template = ERB.new(template("query_type"), nil, '<>').result(binding)
            graphql_namespace.module_eval(graphql_query_type_template)

            graphql_schema_template = ERB.new(template("schema"), nil, '<>').result(binding)
            graphql_namespace.module_eval(graphql_schema_template)
            graphql_namespace.const_get("Schema")
          end
        end
      end
    end
  end
end
