/*
 * Tree-sitter binding for the Lua API, registered as
 * package.preload.treesitter when vis is built with --enable-tree-sitter.
 *
 * The surface is the smallest one lua/vis-treesitter.lua needs: load a
 * grammar, parse a File (read straight from the piece table, no copy),
 * apply an edit to a tree, compile a query and run it over a byte range.
 * Predicate evaluation and the capture-to-style mapping stay in Lua, where
 * the query vocabulary (#lua-match? is a Lua pattern) is native.
 *
 * Included from vis.c after vis-lua.c, so obj_ref_check and the File type
 * are in scope.
 */
#if CONFIG_LUA && CONFIG_TREE_SITTER

#include <dlfcn.h>
#include <tree_sitter/api.h>

#define TS_TYPE_LANGUAGE "treesitter.language"
#define TS_TYPE_PARSER   "treesitter.parser"
#define TS_TYPE_TREE     "treesitter.tree"
#define TS_TYPE_QUERY    "treesitter.query"

/* every handle is a boxed pointer; NULL after an explicit release */
static void ts_lua_box(lua_State *L, void *ptr, const char *type)
{
	void **box = lua_newuserdata(L, sizeof *box);
	*box = ptr;
	luaL_setmetatable(L, type);
}

static void *ts_lua_unbox(lua_State *L, int idx, const char *type)
{
	void **box = luaL_checkudata(L, idx, type);
	if (!*box)
		luaL_error(L, "%s: released", type);
	return *box;
}

/***
 * Load a grammar from a shared object.
 *
 * @function language
 * @tparam string path the shared object, e.g. /usr/lib/tree_sitter/lua.so
 * @tparam string name the grammar name; the symbol tree_sitter_<name> is resolved
 * @return the language, or `nil` and a message
 */
static int ts_lua_language(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	const char *name = luaL_checkstring(L, 2);
	char symbol[128];
	if (snprintf(symbol, sizeof symbol, "tree_sitter_%s", name) >= (int)sizeof symbol)
		return luaL_error(L, "language name too long");

	/* the handle stays open for the life of the process: nodes keep
	 * pointers into the grammar's tables */
	void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (!handle) {
		lua_pushnil(L);
		lua_pushstring(L, dlerror());
		return 2;
	}

	const TSLanguage *(*language_fn)(void);
	*(void **)(&language_fn) = dlsym(handle, symbol);
	if (!language_fn) {
		dlclose(handle);
		lua_pushnil(L);
		lua_pushfstring(L, "%s: no symbol %s", path, symbol);
		return 2;
	}

	const TSLanguage *lang = language_fn();
	uint32_t abi = ts_language_abi_version(lang);
	if (abi > TREE_SITTER_LANGUAGE_VERSION || abi < TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION) {
		dlclose(handle);
		lua_pushnil(L);
		lua_pushfstring(L, "%s: grammar ABI %d, this vis supports %d to %d", path,
		                (int)abi, TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION,
		                TREE_SITTER_LANGUAGE_VERSION);
		return 2;
	}

	ts_lua_box(L, (void *)lang, TS_TYPE_LANGUAGE);
	return 1;
}

/***
 * Create a parser for a language.
 *
 * @function parser
 * @param language as returned by @{language}
 * @return the parser
 */
static int ts_lua_parser(lua_State *L)
{
	const TSLanguage *lang = ts_lua_unbox(L, 1, TS_TYPE_LANGUAGE);
	TSParser *parser = ts_parser_new();
	if (!parser || !ts_parser_set_language(parser, lang)) {
		if (parser)
			ts_parser_delete(parser);
		return luaL_error(L, "cannot create parser");
	}
	ts_lua_box(L, parser, TS_TYPE_PARSER);
	return 1;
}

static int ts_lua_parser_gc(lua_State *L)
{
	void **box = luaL_checkudata(L, 1, TS_TYPE_PARSER);
	if (*box)
		ts_parser_delete(*box);
	*box = NULL;
	return 0;
}

/* TSInput callback: hand tree-sitter the piece containing byte_index */
static const char *ts_lua_read(void *payload, uint32_t byte_index, TSPoint position, uint32_t *bytes_read)
{
	(void)position;
	const Text *txt = payload;
	if (byte_index >= text_size(txt)) {
		*bytes_read = 0;
		return "";
	}
	Iterator it = text_iterator_get(txt, byte_index);
	if (!text_iterator_valid(&it) || it.text >= it.end) {
		*bytes_read = 0;
		return "";
	}
	*bytes_read = (uint32_t)(it.end - it.text);
	return it.text;
}

/***
 * Parse a file.
 *
 * With an old tree that has had every change since its parse applied
 * through @{tree:edit}, the parse is incremental and reuses its nodes.
 * @function parser:parse
 * @tparam File file the file to parse
 * @param[opt] tree the previous tree of this file, edited
 * @return the new tree, or `nil` and a message
 */
static int ts_lua_parser_parse(lua_State *L)
{
	TSParser *parser = ts_lua_unbox(L, 1, TS_TYPE_PARSER);
	File *file = obj_ref_check(L, 2, VIS_LUA_TYPE_FILE);
	TSTree *old = lua_isnoneornil(L, 3) ? NULL : ts_lua_unbox(L, 3, TS_TYPE_TREE);
	if (text_size(file->text) > UINT32_MAX) {
		lua_pushnil(L);
		lua_pushliteral(L, "file too large");
		return 2;
	}
	TSInput input = {
		.payload  = file->text,
		.read     = ts_lua_read,
		.encoding = TSInputEncodingUTF8,
		.decode   = NULL,
	};
	TSTree *tree = ts_parser_parse(parser, old, input);
	if (!tree) {
		lua_pushnil(L);
		lua_pushliteral(L, "parse failed");
		return 2;
	}
	ts_lua_box(L, tree, TS_TYPE_TREE);
	return 1;
}

static int ts_lua_tree_gc(lua_State *L)
{
	void **box = luaL_checkudata(L, 1, TS_TYPE_TREE);
	if (*box)
		ts_tree_delete(*box);
	*box = NULL;
	return 0;
}

/***
 * Record an edit so the next parse can be incremental.
 *
 * Points are zero-based rows and byte columns.
 * @function tree:edit
 * @tparam int start_byte
 * @tparam int old_end_byte
 * @tparam int new_end_byte
 * @tparam int start_row
 * @tparam int start_col
 * @tparam int old_end_row
 * @tparam int old_end_col
 * @tparam int new_end_row
 * @tparam int new_end_col
 */
static int ts_lua_tree_edit(lua_State *L)
{
	TSTree *tree = ts_lua_unbox(L, 1, TS_TYPE_TREE);
	TSInputEdit edit = {
		.start_byte    = luaL_checkinteger(L, 2),
		.old_end_byte  = luaL_checkinteger(L, 3),
		.new_end_byte  = luaL_checkinteger(L, 4),
		.start_point   = { luaL_checkinteger(L, 5), luaL_checkinteger(L, 6) },
		.old_end_point = { luaL_checkinteger(L, 7), luaL_checkinteger(L, 8) },
		.new_end_point = { luaL_checkinteger(L, 9), luaL_checkinteger(L, 10) },
	};
	ts_tree_edit(tree, &edit);
	return 0;
}

/***
 * Whether the parse produced error nodes.
 * @function tree:has_error
 * @treturn bool
 */
static int ts_lua_tree_has_error(lua_State *L)
{
	TSTree *tree = ts_lua_unbox(L, 1, TS_TYPE_TREE);
	lua_pushboolean(L, ts_node_has_error(ts_tree_root_node(tree)));
	return 1;
}

static const char *ts_lua_query_errors[] = {
	[TSQueryErrorNone]      = "none",
	[TSQueryErrorSyntax]    = "syntax",
	[TSQueryErrorNodeType]  = "node type",
	[TSQueryErrorField]     = "field",
	[TSQueryErrorCapture]   = "capture",
	[TSQueryErrorStructure] = "structure",
	[TSQueryErrorLanguage]  = "language",
};

/***
 * Compile a query.
 *
 * @function query
 * @param language as returned by @{language}
 * @tparam string source the query text (a highlights.scm)
 * @return the query, or `nil`, the error kind and the zero-based byte offset of the error
 */
static int ts_lua_query(lua_State *L)
{
	const TSLanguage *lang = ts_lua_unbox(L, 1, TS_TYPE_LANGUAGE);
	size_t len;
	const char *src = luaL_checklstring(L, 2, &len);
	uint32_t offset;
	TSQueryError error;
	TSQuery *query = ts_query_new(lang, src, len, &offset, &error);
	if (!query) {
		lua_pushnil(L);
		lua_pushstring(L, error < LENGTH(ts_lua_query_errors) ? ts_lua_query_errors[error] : "unknown");
		lua_pushinteger(L, offset);
		return 3;
	}
	ts_lua_box(L, query, TS_TYPE_QUERY);
	return 1;
}

static int ts_lua_query_gc(lua_State *L)
{
	void **box = luaL_checkudata(L, 1, TS_TYPE_QUERY);
	if (*box)
		ts_query_delete(*box);
	*box = NULL;
	return 0;
}

/***
 * Capture names, indexed by capture id (one-based).
 * @function query:captures
 * @treturn table array of names without the leading `@`
 */
static int ts_lua_query_captures(lua_State *L)
{
	TSQuery *query = ts_lua_unbox(L, 1, TS_TYPE_QUERY);
	uint32_t count = ts_query_capture_count(query);
	lua_createtable(L, count, 0);
	for (uint32_t i = 0; i < count; i++) {
		uint32_t len;
		const char *name = ts_query_capture_name_for_id(query, i, &len);
		lua_pushlstring(L, name, len);
		lua_rawseti(L, -2, i + 1);
	}
	return 1;
}

/***
 * Predicates per pattern.
 *
 * `predicates[pattern]` is an array of predicates; each predicate is an
 * array whose first element is its name (`eq?`, `lua-match?`, `set!`)
 * followed by its arguments: a capture id (number) or a string literal.
 * @function query:predicates
 * @treturn table
 */
static int ts_lua_query_predicates(lua_State *L)
{
	TSQuery *query = ts_lua_unbox(L, 1, TS_TYPE_QUERY);
	uint32_t patterns = ts_query_pattern_count(query);
	lua_createtable(L, patterns, 0);
	for (uint32_t p = 0; p < patterns; p++) {
		uint32_t nsteps;
		const TSQueryPredicateStep *steps = ts_query_predicates_for_pattern(query, p, &nsteps);
		lua_newtable(L);
		int npred = 0, nargs = 0;
		bool open = false;
		for (uint32_t s = 0; s < nsteps; s++) {
			if (steps[s].type == TSQueryPredicateStepTypeDone) {
				if (open)
					lua_rawseti(L, -2, ++npred);
				open = false;
				continue;
			}
			if (!open) {
				lua_newtable(L);
				open = true;
				nargs = 0;
			}
			if (steps[s].type == TSQueryPredicateStepTypeString) {
				uint32_t len;
				const char *value = ts_query_string_value_for_id(query, steps[s].value_id, &len);
				lua_pushlstring(L, value, len);
			} else {
				lua_pushinteger(L, steps[s].value_id + 1);
			}
			lua_rawseti(L, -2, ++nargs);
		}
		if (open)
			lua_rawseti(L, -2, ++npred);
		lua_rawseti(L, -2, p + 1);
	}
	return 1;
}

/* a predicate step's string value equals the node type */
static bool ts_lua_type_is(const TSQuery *query, const TSQueryPredicateStep *step, const char *type)
{
	if (step->type != TSQueryPredicateStepTypeString)
		return false;
	uint32_t len;
	const char *want = ts_query_string_value_for_id(query, step->value_id, &len);
	return strlen(type) == len && memcmp(type, want, len) == 0;
}

/* #has-parent?, #has-ancestor? and their not- forms need the nodes, so
 * they are decided here; text predicates are left to Lua */
static bool ts_lua_structure_holds(const TSQuery *query, const TSQueryMatch *match)
{
	uint32_t nsteps;
	const TSQueryPredicateStep *steps = ts_query_predicates_for_pattern(query, match->pattern_index, &nsteps);
	for (uint32_t i = 0; i < nsteps; ) {
		uint32_t end = i;
		while (end < nsteps && steps[end].type != TSQueryPredicateStepTypeDone)
			end++;
		if (end - i >= 3 && steps[i].type == TSQueryPredicateStepTypeString &&
		    steps[i + 1].type == TSQueryPredicateStepTypeCapture) {
			uint32_t len;
			const char *name = ts_query_string_value_for_id(query, steps[i].value_id, &len);
			bool negate = strncmp(name, "not-", 4) == 0;
			if (negate)
				name += 4;
			bool parent_only = strcmp(name, "has-parent?") == 0;
			if (parent_only || strcmp(name, "has-ancestor?") == 0) {
				bool found = false;
				for (uint16_t c = 0; c < match->capture_count && !found; c++) {
					if (match->captures[c].index != steps[i + 1].value_id)
						continue;
					TSNode node = ts_node_parent(match->captures[c].node);
					while (!ts_node_is_null(node) && !found) {
						const char *type = ts_node_type(node);
						for (uint32_t s = i + 2; s < end && !found; s++)
							found = ts_lua_type_is(query, &steps[s], type);
						if (parent_only)
							break;
						node = ts_node_parent(node);
					}
				}
				if (found == negate)
					return false;
			}
		}
		i = end + 1;
	}
	return true;
}

/***
 * Run the query over a byte range of a tree.
 *
 * Matches failing a structural predicate (#has-parent?, #has-ancestor?,
 * or their not- forms) are left out; text predicates are the caller's.
 * Returns one flat integer array to keep the per-redraw allocation small:
 * for each match `pattern, capture_count` followed by `capture_id,
 * start_byte, end_byte` per capture. Matches arrive in document order.
 * @function query:exec
 * @param tree
 * @tparam int start_byte
 * @tparam int end_byte
 * @treturn table the flat array
 * @treturn int its length
 */
static int ts_lua_query_exec(lua_State *L)
{
	TSQuery *query = ts_lua_unbox(L, 1, TS_TYPE_QUERY);
	TSTree *tree = ts_lua_unbox(L, 2, TS_TYPE_TREE);
	uint32_t start = luaL_checkinteger(L, 3);
	uint32_t end = luaL_checkinteger(L, 4);

	TSQueryCursor *cursor = ts_query_cursor_new();
	if (!cursor)
		return luaL_error(L, "cannot create query cursor");
	ts_query_cursor_set_byte_range(cursor, start, end);
	ts_query_cursor_exec(cursor, query, ts_tree_root_node(tree));

	lua_newtable(L);
	lua_Integer n = 0;
	TSQueryMatch match;
	while (ts_query_cursor_next_match(cursor, &match)) {
		if (!ts_lua_structure_holds(query, &match))
			continue;
		lua_pushinteger(L, match.pattern_index + 1);
		lua_rawseti(L, -2, ++n);
		lua_pushinteger(L, match.capture_count);
		lua_rawseti(L, -2, ++n);
		for (uint16_t i = 0; i < match.capture_count; i++) {
			TSNode node = match.captures[i].node;
			lua_pushinteger(L, match.captures[i].index + 1);
			lua_rawseti(L, -2, ++n);
			lua_pushinteger(L, ts_node_start_byte(node));
			lua_rawseti(L, -2, ++n);
			lua_pushinteger(L, ts_node_end_byte(node));
			lua_rawseti(L, -2, ++n);
		}
	}
	ts_query_cursor_delete(cursor);
	lua_pushinteger(L, n);
	return 2;
}

static void ts_lua_type(lua_State *L, const char *name, const luaL_Reg *funcs)
{
	luaL_newmetatable(L, name);
	luaL_setfuncs(L, funcs, 0);
	lua_pushvalue(L, -1);
	lua_setfield(L, -2, "__index");
	lua_pop(L, 1);
}

int luaopen_treesitter(lua_State *L)
{
	static const luaL_Reg language_funcs[] = { {0} };
	static const luaL_Reg parser_funcs[] = {
		{ "parse", ts_lua_parser_parse },
		{ "__gc",  ts_lua_parser_gc    },
		{0},
	};
	static const luaL_Reg tree_funcs[] = {
		{ "edit",      ts_lua_tree_edit      },
		{ "has_error", ts_lua_tree_has_error },
		{ "__gc",      ts_lua_tree_gc        },
		{0},
	};
	static const luaL_Reg query_funcs[] = {
		{ "captures",   ts_lua_query_captures   },
		{ "predicates", ts_lua_query_predicates },
		{ "exec",       ts_lua_query_exec       },
		{ "__gc",       ts_lua_query_gc         },
		{0},
	};
	static const luaL_Reg module_funcs[] = {
		{ "language", ts_lua_language },
		{ "parser",   ts_lua_parser   },
		{ "query",    ts_lua_query    },
		{0},
	};

	ts_lua_type(L, TS_TYPE_LANGUAGE, language_funcs);
	ts_lua_type(L, TS_TYPE_PARSER,   parser_funcs);
	ts_lua_type(L, TS_TYPE_TREE,     tree_funcs);
	ts_lua_type(L, TS_TYPE_QUERY,    query_funcs);

	luaL_newlib(L, module_funcs);
	lua_pushinteger(L, TREE_SITTER_LANGUAGE_VERSION);
	lua_setfield(L, -2, "abi_version");
	lua_pushinteger(L, TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION);
	lua_setfield(L, -2, "abi_min_version");
	return 1;
}

#endif /* CONFIG_LUA && CONFIG_TREE_SITTER */
