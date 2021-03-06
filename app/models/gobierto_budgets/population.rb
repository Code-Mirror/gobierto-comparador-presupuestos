module GobiertoBudgets
  class Population

    include CommonQueryBehavior

    FILTER_MIN = 0
    FILTER_MAX = 5000000

    def self.for(ine_code, year)
      year = year - 1 if GobiertoBudgets::SearchEngineConfiguration::Year.fallback_year?(year)

      return for_places(ine_code, year) if ine_code.is_a?(Array)
      population_query_results(ine_code: ine_code, year: year).first['value'].to_f
    end

    def self.for_places(ine_codes, year)
      year = year - 1 if GobiertoBudgets::SearchEngineConfiguration::Year.fallback_year?(year)

      population_query_results(ine_codes: ine_codes, year: year)
    end

    def self.for_year(year)
      year = year - 1 if GobiertoBudgets::SearchEngineConfiguration::Year.fallback_year?(year)

      population_query_results(year: year)
    end

    def self.for_ranking(year, offset, per_page, filters)
      year = year - 1 if GobiertoBudgets::SearchEngineConfiguration::Year.fallback_year?(year)

      response = population_query(year: year, offset: offset, per_page: per_page, filters: filters)
      total_elements = response['hits']['total']
      if result = response['hits']['hits']
        return result.map{|h| h['_source']}, total_elements
      else
        return [], 0
      end
    end

    def self.ranking_hash_for(ine_code, year)
      year = year - 1 if GobiertoBudgets::SearchEngineConfiguration::Year.fallback_year?(year)

      buckets = for_year year

      if row = buckets.detect{|v| v['ine_code'] == ine_code }
        value = row['value']
      end

      position = buckets.index(row) + 1 rescue nil

      return {
        value: value,
        position: position,
        total_elements: buckets.length
      }
    end

    def self.place_position_in_ranking(year, ine_code, filters)
      year = year - 1 if GobiertoBudgets::SearchEngineConfiguration::Year.fallback_year?(year)

      id = [ine_code, year].join('/')
      response = population_query({year: year, to_rank: true, filters: filters})
      buckets = response['hits']['hits'].map{|h| h['_id']}
      position = buckets.index(id) ? buckets.index(id) + 1 : 0;
      return position + 1
    end

    private

    def self.population_query(options)
      terms = []
      ine_codes = []
      if options[:ine_codes].present?
        ine_codes.concat(options[:ine_codes])
      end

      if GobiertoBudgets::SearchEngineConfiguration::Scopes.places_scope?
        if ine_codes.any?
          ine_codes = ine_codes & GobiertoBudgets::SearchEngineConfiguration::Scopes.places_scope
        else
          ine_codes = GobiertoBudgets::SearchEngineConfiguration::Scopes.places_scope
        end
      end

      append_ine_codes(terms, ine_codes)
      terms << {term: { ine_code: options[:ine_code] }} if options[:ine_code].present?
      terms << {term: { year: options[:year] }}

      if options[:filters].present?
        population_filter =  options[:filters][:population]
        total_filter = options[:filters][:total]
        per_inhabitant_filter = options[:filters][:per_inhabitant]
        aarr_filter = options[:filters][:aarr] if options[:filters][:aarr] != 'undefined'
      end

      if total_filter || per_inhabitant_filter
        budget_filters = {}

        if (total_filter && (total_filter[:from].to_i > BudgetTotal::TOTAL_FILTER_MIN || total_filter[:to].to_i < BudgetTotal::TOTAL_FILTER_MAX))
          budget_filters[:total] = total_filter
        end

        if (per_inhabitant_filter && (per_inhabitant_filter[:from].to_i > BudgetTotal::PER_INHABITANT_FILTER_MIN || per_inhabitant_filter[:to].to_i < BudgetTotal::PER_INHABITANT_FILTER_MAX))
          budget_filters[:per_inhabitant] = per_inhabitant_filter
        end

        budget_filters.merge!(aarr: aarr_filter) if aarr_filter

        results, total_elements = BudgetTotal.for_ranking(options[:year], 'total_budget', GobiertoBudgets::BudgetLine::EXPENSE, 0, nil, budget_filters)
        ine_codes = results.map{|p| p['ine_code']}
        append_ine_codes(terms, ine_codes)
      end

      if (population_filter && (population_filter[:from].to_i > Population::FILTER_MIN || population_filter[:to].to_i < Population::FILTER_MAX))
        terms << {range: { value: { gte: population_filter[:from].to_i, lte: population_filter[:to].to_i} }}
      end

      terms << { term: { autonomous_region_id: aarr_filter } } unless aarr_filter.blank?

      query = {
        sort: [
          { value: { order: 'desc' } }
        ],
        query: {
          filtered: {
            filter: {
              bool: {
                must: terms
              }
            }
          }
        },
        size: 10_000
      }

      query.merge!(size: options[:per_page]) if options[:per_page].present?
      query.merge!(from: options[:offset]) if options[:offset].present?
      query.merge!(_source: false) if options[:to_rank]

      SearchEngine.client.search(
        index: SearchEngineConfiguration::Data.index,
        type: SearchEngineConfiguration::Data.type_population,
        body: query,
        filter_path: options[:to_rank] ? "hits.total" : "hits.hits._source,hits.total",
        _source: ["value", "ine_code"]
      )
    end

    def self.population_query_results(options)
      if result = population_query(options)['hits']['hits']
        result.map{|h| h['_source']}
      else
        []
      end
    end

  end
end
