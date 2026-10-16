extends RefCounted
## Explicit compatibility defaults for otherwise unconfigured collection sources.
## Match the complete decoded source (LF newlines), never just its filename.
const PROFILES := {
	"1efde269eca772679cddc5a962b09b6bfe2e1a79c8f301bdde9e4b3b156f20db": {
		"warning":"Repaired upstream box clamp: test transformed texture coordinates instead of pixel-valued gl_FragCoord against 0..1.",
		"replacements":{"vec2 bordertest = gl_FragCoord.xy;":"vec2 bordertest = vTexCoord;"}
	},
	"806f6f772b3d0c2152cb9a80af4ddc1a8e978f1edac15c9472fa5753d20c7ffe": {
		"warning":"Repaired upstream box-max clamp: test transformed texture coordinates instead of pixel-valued gl_FragCoord against 0..1.",
		"replacements":{"vec2 bordertest = gl_FragCoord.xy;":"vec2 bordertest = vTexCoord;"}
	},
	"ebcede56c7bada72eb60290e2d6e9b13fa5bb94dbd62faaad622ffef02c0d806": {
		"warning":"Standalone imgborder uses the collection's 2560x1600 border image; an explicit preset can override this default.",
		"preset":{"textures":"bg","bg":"../imgborder/border-2560x1600.png"}
	},
	"ea5cb24df47a93ca86c9be5afa17833eb3645f6a12504e01f76aa246419f80e7": {
		"warning":"Standalone crtsim screen uses its sibling mask.png with the filtering and repeat settings from crtsim.glslp.",
		"preset":{"textures":"shadowMaskSampler","shadowMaskSampler":"mask.png","shadowMaskSampler_linear":"true","shadowMaskSampler_wrap_mode":"repeat"}
	},
	"44dbab1a324001cf4be75787845ba3e140c84036b6f1aea16ae0a687e6452f4a": {
		"warning":"Standalone DAC_LUT uses its sibling NesTable.png with nearest filtering, as configured by gtu-famicom.glslp. The input must contain NES palette indices.",
		"preset":{"textures":"nestable","nestable":"NesTable.png","nestable_linear":"false","nestable_wrap_mode":"clamp_to_border"}
	},
	"30b400666c98d8894f7e90fda87868aa87285b69c9ab57c624463dafde2f2cae": {
		"warning":"Repaired Grade's mismatched pragma/uniform names. Standalone Grade uses the collection's identity 16/64 LUTs; an explicit preset can supply custom LUTs.",
		"preset":{"textures":"SamplerLUT1;SamplerLUT2","SamplerLUT1":"../reshade/shaders/LUT/16.png","SamplerLUT2":"../reshade/shaders/LUT/64.png","SamplerLUT1_linear":"true","SamplerLUT2_linear":"true"},
		"uniform_aliases":{"gamma_in":"g_gamma_in","signal":"g_signal_type","gamma_type":"g_gamma_type","crtgamut":"g_crtgamut","SPC":"g_space_out","hue_degrees":"g_hue_degrees","I_SHIFT":"g_I_SHIFT","Q_SHIFT":"g_Q_SHIFT","I_MUL":"g_I_MUL","Q_MUL":"g_Q_MUL","lum_fix":"g_lum_fix","vignette":"g_vignette","vstr":"g_vstr","vpower":"g_vpower","lum":"g_lum","cntrst":"g_cntrst","mid":"g_mid","vibr":"g_vibr","satr":"g_satr","satg":"g_satg","satb":"g_satb","lift":"g_lift"}
	},
	"2111c7b2ae196efeec818c473eab4adbeb739624656eaa3a84f880e7da046d7f": {
		"warning":"Repaired upstream box-center clamp: test transformed texture coordinates instead of pixel-valued gl_FragCoord against 0..1.",
		"replacements":{"vec2 bordertest = gl_FragCoord.xy;":"vec2 bordertest = vTexCoord;"}
	},
}

static func get_profile(source: String) -> Dictionary:
	# Hash after the importer's UTF-8/Latin-1 decoding. Only newline style is
	# ignored; edited source must not silently receive a collection repair.
	return PROFILES.get(source.replace("\r\n", "\n").sha256_text(), {})

static func prepare(source: String, profile: Dictionary) -> String:
	for before: String in profile.get("replacements", {}):
		source = source.replace(before, profile.replacements[before])
	# Token boundaries keep an alias from rewriting part of a longer uniform.
	# Keys come from the fixed, exact-source profiles above, never shader text.
	for before: String in profile.get("uniform_aliases", {}):
		var regex := RegEx.new()
		regex.compile("\\b" + before + "\\b")
		source = regex.sub(source, profile.uniform_aliases[before], true)
	return source
