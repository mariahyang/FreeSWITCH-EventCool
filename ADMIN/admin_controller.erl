-module(admin_controller, [Req]).
-compile(export_all).
-define(RECORDS_PER_PAGE, 100).

'_auth'(_) ->
    case Req:peer_ip() of
        {192, 168, _, _} ->
            {ok, local};
        {127, 0, 0, 1} ->
            {ok, local};
        {10, 0, _, _} ->
            {ok, local};
        _ ->
            {redirect, "/admin/access_denied"}
    end.

model('GET', [], Authorization) ->
    {ok, [{records, []}, {models, boss_files:model_list()}, {this_model, ""}]};
model('GET', [ModelName], Authorization) ->
    model('GET', [ModelName, "1"], Authorization);
model('GET', [ModelName, PageName], Authorization) ->
    Page = list_to_integer(PageName),
    Model = list_to_atom(ModelName),
    RecordCount = boss_db:count(Model),
    Records = boss_db:find(Model, [], ?RECORDS_PER_PAGE, (Page - 1) * ?RECORDS_PER_PAGE, id, str_descending),
    AttributesWithDataTypes = lists:map(fun(Record) ->
                lists:map(fun({Key, Val}) ->
                            {Key, Val, boss_db:data_type(Key, Val)}
                    end, Record:attributes())
        end, Records),
    AttributeNames = case length(Records) of
        0 -> [];
        _ -> (lists:nth(1, Records)):attribute_names()
    end,
    Pages = lists:seq(1, ((RecordCount-1) div ?RECORDS_PER_PAGE)+1),
    {ok, 
        [{records, AttributesWithDataTypes}, {attribute_names, AttributeNames}, 
            {models, boss_files:model_list()}, {this_model, ModelName}, 
            {pages, Pages}, {this_page, Page}], 
        [{"Cache-Control", "no-cache"}]}.

record('GET', [RecordId], Authorization) ->
    Record = boss_db:find(RecordId),
    AttributesWithDataTypes = lists:map(fun({Key, Val}) ->
                {Key, Val, boss_db:data_type(Key, Val)}
        end, Record:attributes()),
    {ok, [{'record', Record}, {'attributes', AttributesWithDataTypes}, 
            {'type', boss_db:type(RecordId)}]}.

delete('GET', [RecordId], Authorization) ->
    {ok, [{'record', boss_db:find(RecordId)}]};
delete('POST', [RecordId], Authorization) ->
    Type = boss_db:type(RecordId),
    boss_db:delete(RecordId),
    {redirect, "/admin/model/" ++ atom_to_list(Type)}.

create(Method, [RecordType], Authorization) ->
    case lists:member(RecordType, boss_files:model_list()) of
        true ->
            Module = list_to_atom(RecordType),
            NumArgs = proplists:get_value('new', Module:module_info(exports)),
            case Method of
                'GET' ->
                    Record = apply(list_to_atom(RecordType), 'new', lists:seq(1, NumArgs)),
                    {ok, [{type, RecordType}, {'record', Record}]};
                'POST' ->
                    DummyRecord = apply(list_to_atom(RecordType), 'new', lists:seq(1, NumArgs)),
                    Record = apply(list_to_atom(RecordType), 'new', 
                        lists:map(fun('id') -> 'id'; 
                                (A) ->
                                    AttrName = atom_to_list(A),
                                    Val = Req:post_param(AttrName),
                                    case lists:suffix("_time", AttrName) of
                                        true ->
                                            case Req:post_param(AttrName) of
                                                "now" -> erlang:now();
                                                _ -> ""
                                            end;
                                        _ -> Val
                                    end
                            end, DummyRecord:attribute_names())),
                    case Record:save() of
                        {ok, SavedRecord} ->
                            {redirect, "/admin/record/"++SavedRecord:id()};
                        {error, Errors} ->
                            {ok, [{errors, Errors}, {type, RecordType}, {'record', Record}]}
                    end
            end;
        _ ->
            {error, "Nonesuch model."}
    end.

lang('GET', [], Auth) ->
    Languages = boss_files:language_list(),
    {ok, [{languages, Languages}]};
lang('GET', [Lang], Auth) ->
    Languages = boss_files:language_list(),
    {Untranslated, Translated} = boss_lang:extract_strings(Lang),
    LastModified = filelib:last_modified(boss_files:lang_path(Lang)),
    {ok, [{this_lang, Lang}, {languages, Languages},
            {untranslated_messages, Untranslated},
            {translated_messages, Translated},
            {last_modified, LastModified}],
        [{"Cache-Control", "no-cache"}]};
lang('POST', [Lang|Fmt], Auth) ->
    LangFile = boss_files:lang_path(Lang),
    {ok, IODevice} = file:open(LangFile, [write, append]),
    lists:map(fun(Message) ->
                Original = proplists:get_value("orig", Message),
                Translation = proplists:get_value("trans", Message),
                case Translation of
                    "" -> ok;
                    _ -> 
                        file:write(IODevice, 
                            "\nmsgid \""++boss_lang:escape_quotes(Original)++"\"\n"),
                        file:write(IODevice, 
                            "msgstr \""++boss_lang:escape_quotes(Translation)++"\"\n")
                end
        end, Req:deep_post_param(["messages"])),
    file:close(IODevice),
    boss_translator:reload(Lang),
    case Fmt of
        ["json"] -> {json, [{success, true}]};
        [] -> {redirect, "/admin/lang/"++Lang}
    end.

create_lang('GET', [], Auth) ->
    {ok, [{languages, boss_files:language_list()}]};
create_lang('POST', [], Auth) ->
    % TODO sanitize
    NewLang = Req:post_param("language"),
    LangFile = boss_files:lang_path(NewLang),
    {ok, IODevice} = file:open(LangFile, [write]),
    file:close(IODevice),
    {redirect, "/admin/lang/"++NewLang}.

delete_lang('GET', [Lang], Auth) ->
    {ok, [{this_lang, Lang}]};
delete_lang('POST', [Lang], Auth) ->
    ok = file:delete(boss_files:lang_path(Lang)),
    {redirect, "/admin/lang"}.

big_red_button('GET', [], Auth) ->
    Languages = lists:map(fun(Lang) ->
                {Untranslated, Translated} = boss_lang:extract_strings(Lang),
                [{code, Lang}, {untranslated_strings, Untranslated}]
        end, boss_files:language_list()),
    {ok, [{languages, Languages}, {strings, boss_lang:extract_strings()}]}.
