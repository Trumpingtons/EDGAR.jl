# Faithful translation of edgartools' edgar/documents/config.py.
# ParserConfig (and DetectionThresholds) — the defaults the builder, strategies and detectors read. Field
# names and default values mirror the Python dataclass exactly.

Base.@kwdef mutable struct DetectionThresholds
    min_confidence::Float64 = 0.6
    cross_validation_boost::Float64 = 1.2
    disagreement_penalty::Float64 = 0.8
    boundary_overlap_penalty::Float64 = 0.9
    enable_cross_validation::Bool = false
    thresholds_by_form::Dict{String,Dict{String,Float64}} = Dict{String,Dict{String,Float64}}()
end

_default_section_patterns() = Dict{String,Vector{String}}(
    "business" => ["item\\s+1\\.?\\s*business", "business\\s+overview", "our\\s+business"],
    "risk_factors" => ["item\\s+1a\\.?\\s*risk\\s+factors", "risk\\s+factors", "factors\\s+that\\s+may\\s+affect"],
    "properties" => ["item\\s+2\\.?\\s*properties", "properties"],
    "legal_proceedings" => ["item\\s+3\\.?\\s*legal\\s+proceedings", "legal\\s+proceedings", "litigation"],
    "mda" => ["item\\s+7\\.?\\s*management\\'?s?\\s+discussion", "md&a", "management\\'?s?\\s+discussion\\s+and\\s+analysis"],
    "financial_statements" => ["item\\s+8\\.?\\s*financial\\s+statements", "consolidated\\s+financial\\s+statements", "financial\\s+statements"],
)

_default_features() = Dict{String,Bool}(
    "ml_header_detection" => true, "semantic_analysis" => true, "table_understanding" => true,
    "xbrl_validation" => true, "auto_section_detection" => true, "smart_text_extraction" => true,
    "footnote_linking" => true, "cross_reference_resolution" => true)

Base.@kwdef mutable struct ParserConfig
    # Performance settings
    max_document_size::Int = 160 * 1024 * 1024
    streaming_threshold::Int = 10 * 1024 * 1024
    cache_size::Int = 1000
    enable_parallel::Bool = true
    max_workers::Union{Nothing,Int} = nothing
    # Parsing settings
    strict_mode::Bool = false
    extract_xbrl::Bool = true
    extract_styles::Bool = true
    preserve_whitespace::Bool = false
    normalize_text::Bool = true
    extract_links::Bool = true
    extract_images::Bool = false
    # AI optimization
    optimize_for_ai::Bool = true
    max_token_estimation::Int = 100_000
    chunk_size::Int = 512
    chunk_overlap::Int = 128
    # Table processing
    table_extraction::Bool = true
    detect_table_types::Bool = true
    extract_table_relationships::Bool = true
    fast_table_rendering::Bool = true
    # Section detection
    detect_sections::Bool = true
    eager_section_extraction::Bool = false
    form::Union{Nothing,String} = nothing
    detection_thresholds::DetectionThresholds = DetectionThresholds()
    section_patterns::Dict{String,Vector{String}} = _default_section_patterns()
    # Feature flags
    features::Dict{String,Bool} = _default_features()
    # Header detection settings
    header_detection_threshold::Float64 = 0.6
    header_detection_methods::Vector{String} = ["style", "pattern", "structural", "contextual"]
    # Text extraction settings
    min_text_length::Int = 10
    merge_adjacent_nodes::Bool = true
    merge_distance::Int = 2
    # Performance monitoring
    enable_profiling::Bool = false
    log_performance::Bool = false
end

# Feature flag lookup (config.features.get(name)).
feature(c::ParserConfig, name::AbstractString, default::Bool = false) = get(c.features, name, default)
