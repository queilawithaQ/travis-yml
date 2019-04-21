# frozen_string_literal: true
#
#                     .......
#                       '.   ''..
#                        |       "'.
#                        /          ''.
#                      ./              ''.
#                   ..".                  '.
#   .....""\::......'   '"'...             ':.
#    ''..         '""'.:.'..  '"'..          "'\
#       '".   '.         "" '''... '"'..      '.'.
#          ".   \.        ""'... .''..  ''... ./  '.
#            \   ''..           \.'".."'..  "..     ".
#             \     .' ".     '"  '.  '"..'\.  '.    '.
#              |  .     .\.. "'     ''..../"."\. '\.   '.
#              |.'        ............     \|'\.'. '\.   .
#             | ...'\::.  '""""""""' ...../""'..".'. '\   \
#            /   ""'          ''      .  |  """ /:' '. ".  \
#           "".    '"""  ...." .'' ' '. '"":::::::| .''.'\  \
#              ".  """'./'  '";  ..'"..'/"   ..."" .:"..\ ". |
#                \           ."".. "' ' |  / /\.""'    ./:./ |
#                '     ..  ..'"     .'./  / ."     .."'   '/ \
#                 |..'" .'" .     ..'/' ." /'   ./'  ...''."'.\
#                /__ ""      '\..'' ..".' /    .' ."'        '..
#                    "'.  '"."  .../'.'  /    .'./             '
#                       ".  |  .\/'""/. |'    |  |
#                        '\ '.".' .'\. \ \    .  |.          ".
#                         './\'  "   \  \.\./""":'|..        '\
#                         |:'  ... |  '. '.'\. '\    "'.  \.  \\
#                        .:\...    |   '  :  '". '   ."|   \.  :\.
#                             '/..   ..  ''           '.\   \/.'.'.
#                            ." |/./"      ..../ '".    "\   '."/./..
#                           .'  /'     ..""  |.'    :..   '""""\.    \
#                          /' ."     ./' |.  \'    ."'.""     |/   '" '..
#                         /  /'."' ""\/  '| /' \."   .\..    ./          \
#                        |' |\"'.     '.  |\.    '""\.  '::/"./   .://'   \
#                       .'  |/. ''.    '| |. |:| ...  '/".  '\  """\":/". '
#                       /  ||. ".../:|  | .\"'\    ./ .|  \ |'.    '\ \  \|
#                       |  |'::..   .  .::'"\.:   .:/\/'  '|/\\      '.\ ''
#                       . || |"::::"' /'    |\' /"\//'    .\'||
#                       | '| |...//  .'  ....   .""       // ||
#                       |  ||'  / | .' ." ./.".         ./"  ||
#                       |  ||  /| | /''.\/|'|/|              '
#                       .  \ \ \ .. ./' |\"\/||
#                        \ '. \ \  "'   "  / '
#                         \ '. '."'.      '
#                          ". ". "..'"'..                      -hrr-
#                            ". "'..""'.:""..
#                              "'..  "'.  '"'"':..
#                                  '"....""'..'". ".
#                                        '"" .    " "..
#                                              '"\: .  \
#                                                  '\:  '.
#                                                     '\  \
#                                                       '. \
#                                                         ' \
#                                                          '.\
#                                                            '

module Travis
  module Yml
    module Schema
      module Type
        module Expand
          extend self

          def apply(node)
            Node.expand(node)
          end

          class Node
            include Helper::Obj, Registry

            def self.expand(node)
              registered?(node.type) ? self[node.type].new.apply(node) : node
            end

            def expand(node)
              self.class.expand(node)
            end
          end

          # class Any < Node
          #   register :any
          #
          #   def apply(node)
          #     node.schemas.replace(node.map { |node| expand(node) })
          #     node
          #   end
          # end

          class Map < Node
            register :map

            def apply(node)
              node = expand_map(node)
              node = expand_includes(node) if node.includes?
              other = includes(node) if node.includes?
              other = prefix(other || node, node[node.prefix], node.prefix) if node.prefix?
              other || node
            end

            def expand_map(node)
              map = node.map { |key, node| [key, expand(node)] }.to_h
              node.mappings.replace(map)
              node
            end

            def expand_includes(node)
              includes = node.includes.map { |node| expand(node) }
              node.includes.replace(includes)
              node
            end

            # If a Map has any includes then we turn this into an All holding
            # the Map and all of its includes.
            #
            # E.g.:
            #
            #   map(includes: [a, b]) -> all(map, a, b)
            #
            def includes(node)
              all = node.transform(:all)
              all.unset :prefix, :includes, :changes, :keys, :normal, :required, :unique
              all.schemas = [node, *node.includes]

              all.schemas.each.with_index do |node, ix|
                node.set :normal, nil
                node.set :export, false
                node.parent = all
              end

              all
            end

            # If the Map has a prefix we also accept the form of the schema
            # mapped with the prefix key. Therefore the Map gets expanded into
            # an Any with the same Map, and the schema mapped with the prefixed
            # key.
            #
            # E.g. if the prefixed key maps to a Str then we return an Any with
            # a Map and a Str:
            #
            #   map(foo: str) -> any(map(foo: str), str)
            #
            def prefix(node, child, prefix)
              any = node.transform(:any)
              any.schemas = [node, child]
              any.unset :prefix, :changes, :keys, :normal, :required, :unique

              child.example = node.examples[prefix]

              any.schemas.each.with_index do |node, ix|
                node.set :normal, ix == 0 ? true : nil
                node.set :export, false
                node.parent = any
              end

              any
            end
          end

          class Schema < Map
            register :schema

            def includes(node)
              all = super(node.transform(:map))
              opts = { title: node.title, schema: all, expand: node.expand }
              Type::Schema.new(nil, opts)
            end
          end

          class Seq < Node
            register :seq

            def apply(node)
              type = detect(node, :str, :secure)
              return ref("#{type}s", node) if type
              node = expand_seq(node)
              node = wrap(node)
              node
            end

            def expand_seq(node)
              node.schemas.replace(node.map { |node| expand(node) })
              node
            end

            # For each of the Seq's schemas we want to include a Seq with that
            # schema, plus the schema itself.
            #
            # E.g. a Seq with a single Str schema should become an Any with the
            # same Seq, and the same Str:
            #
            #   seq(str) -> any(seq(str), str)
            #
            # If the first schema is an Any then this was just expanded from a
            # prefixed Map. In this case case want to use this Any's schemas to
            # replace the Seq's schemas.
            #
            # I.e. a Seq with an Any that has a Map and a Str needs to become
            # an Any with four schemas:
            #
            #   seq(map, str) -> any(seq(map), map, seq(str), str)
            #
            def wrap(node)
              schemas = node.first.is?(:any) ? node.schemas.first.schemas : node.schemas
              schemas = schemas.map do |schema|
                seq = node.transform(:seq)
                seq.schemas.replace([schema])
                [seq, schema]
              end.flatten

              any = node.transform(:any)
              any.schemas = schemas
              any.unset :changes, :keys, :normal, :required, :unique

              any.each.with_index do |node, ix|
                node.set(:normal, ix == 0 ? true : nil)
                node.set(:export, false)
                node.parent = any
              end

              any
            end

            # For the predefined schemas :strs and :secures we can simply
            # return the reference to these.
            #
            def ref(ref, node)
              ref = node.transform(:ref, ref: ref)
              ref.set :namespace, node.namespace # ??
              ref
            end

            def detect(node, *types)
              types.detect { |type| all?(node, type) }
            end

            def all?(node, type)
              node.all?(&:"#{type}?") && node.none?(&:enum?) && node.none?(&:vars?)
            end
          end
        end
      end
    end
  end
end
