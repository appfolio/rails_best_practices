# encoding: utf-8
require 'rails_best_practices/reviews/review'

module RailsBestPractices
  module Reviews
    # Review db/schema.rb file to make sure every reference key has a database index.
    #
    # See the best practice details here http://rails-bestpractices.com/posts/21-always-add-db-index
    #
    # Implementation:
    #
    # Review process:
    #   only check the command and command_calls nodes and at the end of review process,
    #   if the subject of command node is "create_table", then remember the table names
    #   if the subject of command_call node is "integer" and suffix with id, then remember it as foreign key
    #   if the sujbect of command_call node is "string", the name of it is _type suffixed and there is an integer column _id suffixed, then remember it as polymorphic foreign key
    #   if the subject of command node is "add_index", then remember the index columns
    #   after all of these, at the end of review process
    #
    #       ActiveRecord::Schema.define(:version => 20101201111111) do
    #         ......
    #       end
    #
    #   if there are any foreign keys not existed in index columns,
    #   then the foreign keys should add db index.
    class AlwaysAddDbIndexReview < Review
      include Afterable

      interesting_nodes :command, :command_call
      interesting_files SCHEMA_FILE

      def url
        "http://rails-bestpractices.com/posts/21-always-add-db-index"
      end

      def initialize
        super
        @index_columns = {}
        @foreign_keys = {}
        @table_nodes = {}
      end

      # check command_call node.
      #
      # if the message of command_call node is "create_table", then remember the table name.
      # if the message of command_call node is "add_index", then remember it as index columns.
      def start_command_call(node)
        case node.message.to_s
        when "integer", "string"
          remember_foreign_key_columns(node)
        else
        end
      end

      # check command node.
      #
      # if the message of command node is "integer",
      # then remember it as a foreign key of last create table name.
      #
      # if the message of command node is "type" and the name of argument is _type suffixed,
      # then remember it with _id suffixed column as polymorphic foreign key.
      def start_command(node)
        case node.message.to_s
        when "create_table"
          remember_table_nodes(node)
        when "add_index"
          remember_index_columns(node)
        end
      end

      # check at the end of review process.
      #
      # compare foreign keys and index columns,
      # if there are any foreign keys not existed in index columns,
      # then we should add db index for that foreign keys.
      def after_review
        remove_table_not_exist_foreign_keys
        remove_only_type_foreign_keys
        combine_polymorphic_foreign_keys
        @foreign_keys.each do |table, foreign_key|
          table_node = @table_nodes[table]
          foreign_key.each do |column|
            if indexed?(table, column)
              add_error "always add db index (#{table} => [#{Array(column).join(', ')}])", table_node.file, table_node.line
            end
          end
        end
      end

      private
        # remember the node as index columns
        def remember_index_columns(node)
          table_name = node.arguments.all.first.to_s
          index_column = node.arguments.all[1].to_object

          @index_columns[table_name] ||= []
          @index_columns[table_name] << index_column
        end

        # remember table nodes
        def remember_table_nodes(node)
          @table_name = node.arguments.all.first.to_s
          @table_nodes[@table_name] = node
        end


        # remember foreign key columns
        def remember_foreign_key_columns(node)
          table_name = @table_name
          foreign_key_column = node.arguments.all.first.to_s
          @foreign_keys[table_name] ||= []
          if foreign_key_column =~ /(.*?)_id$/
            if @foreign_keys[table_name].delete("#{$1}_type")
              @foreign_keys[table_name] << ["#{$1}_id", "#{$1}_type"]
            else
              @foreign_keys[table_name] << foreign_key_column
            end
          elsif foreign_key_column =~ /(.*?)_type$/
            if @foreign_keys[table_name].delete("#{$1}_id")
              @foreign_keys[table_name] << ["#{$1}_id", "#{$1}_type"]
            else
              @foreign_keys[table_name] << foreign_key_column
            end
          end
        end

        # remove the non foreign keys without corresponding tables.
        def remove_table_not_exist_foreign_keys
          @foreign_keys.each do |table, foreign_keys|
            foreign_keys.delete_if do |key|
              if key =~ /_id$/
                class_name = Prepares.model_associations.get_association_class_name(table, key[0..-4])
                class_name ? !@table_nodes[class_name.table_name] : !@table_nodes[key[0..-4].pluralize]
              end
            end
          end
        end

        # remove the non foreign keys with only _type column.
        def remove_only_type_foreign_keys
          @foreign_keys.each { |table, foreign_keys|
            foreign_keys.delete_if { |key| key =~ /_type$/ }
          }
        end

        # combine polymorphic foreign keys, e.g.
        #     [tagger_id], [tagger_type] => [tagger_id, tagger_type]
        def combine_polymorphic_foreign_keys
          @index_columns.each { |table, foreign_keys|
            foreign_id_keys = foreign_keys.select { |key| key.size == 1 && key.first =~ /_id/ }
            foreign_type_keys = foreign_keys.select { |key| key.size == 1 && key.first =~ /_type/ }
            foreign_id_keys.each do |id_key|
              if type_key = foreign_type_keys.detect { |type_key| type_key.first == id_key.first.sub(/_id/, '') + "_type" }
                foreign_keys.delete(id_key)
                foreign_keys.delete(type_key)
                foreign_keys << id_key + type_key
              end
            end
          }
        end

        # check if the table's column is indexed.
        def indexed?(table, column)
          index_columns = @index_columns[table]
          !index_columns || !index_columns.any? { |e| greater_than_or_equal(Array(e), Array(column)) }
        end

        # check if more_array is greater than less_array or equal to less_array.
        def greater_than_or_equal(more_array, less_array)
          more_size = more_array.size
          less_size = less_array.size
          (more_array - less_array).size == more_size - less_size
        end
    end
  end
end
