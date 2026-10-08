"""C1 graph shape; semantic/type/reference/reachability checks run in core."""


def graph_schema():
    code = {"type": "string", "pattern": "^[A-Za-z][A-Za-z0-9_]{0,63}$"}
    uuid = {"type": "string", "format": "uuid"}
    text = {"type": "string", "minLength": 1, "maxLength": 2000}
    title = {**text, "maxLength": 120}
    timer = {"type": "integer", "minimum": 1000, "maximum": 900000}
    ref = {"$ref": "#/$defs/condition"}
    def obj(props, required=None):
        return {"type": "object", "properties": props,
                "required": list(props) if required is None else required, "additionalProperties": False}
    def arr(items, minimum=0, maximum=50):
        return {"type": "array", "items": items, "minItems": minimum, "maxItems": maximum}
    condition = {"oneOf": [
        obj({"all": arr(ref, maximum=10)}), obj({"any": arr(ref, 1, 10)}),
        obj({"not": ref}), obj({"public_clue": code}), obj({"knows_clue": code}),
        obj({"owns_item": code}), obj({"var": code, "eq": {"type": ["boolean", "integer"]}}),
    ]}
    effects = {"oneOf": [
        obj({"grant_clue": code, "visibility": {"enum": ["actor", "public"]}}),
        obj({"grant_item": code, "visibility": {"enum": ["actor", "public"]}}),
        obj({"set_variable": code, "value": {"type": ["boolean", "integer"]}}),
    ]}
    variable = {"oneOf": [
        obj({"type": {"const": "bool"}, "initial": {"type": "boolean"}}),
        obj({"type": {"const": "int"}, "initial": {"type": "integer"},
             "min": {"type": "integer"}, "max": {"type": "integer"}}),
    ]}
    props = {
        "schema_version": {"const": 2}, "story_id": uuid, "title": title,
        "seat_count": {"type": "integer", "minimum": 2, "maximum": 4},
        "roles": {**arr(code, 2, 4), "uniqueItems": True},
        "phases": {"const": ["briefing", "exploration", "decision"]},
        "variables": {"type": "object", "maxProperties": 20, "propertyNames": code, "additionalProperties": variable},
        "actions": arr(obj({"id": code, "role": code, "phase": {"const": "exploration"},
                            "requires": ref, "effects": arr(effects, 1, 10), "label": title},
                           ["id", "role", "phase", "requires", "effects"]), 1, 50),
        "decision": obj({"duration_ms": timer, "options": {**arr(code, 1, 10), "uniqueItems": True},
                         "eligibility": {"type": "object", "propertyNames": code, "additionalProperties": ref},
                         "default_option": code, "tie_priority": {**arr(code, 1, 10), "uniqueItems": True},
                         "endings": {"type": "object", "propertyNames": code, "additionalProperties": code}}),
        "timing": obj({key: timer for key in ["exploration_ms", "interlude_ms", "ending_ms"]}),
        "media": {**arr(code, 5, 16), "uniqueItems": True},
        "assets": arr(obj({"media_id": code, "asset_id": uuid,
                           "sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
                           "duration_ms": timer, "summary": text, "source": text}), 5, 16),
        "asset_status": {"enum": ["programmatic_demo_ready", "ready", "draft", "missing_original_video"]},
        "demo_only": {"type": "boolean"}, "description": text, "min_protocol_version": {"const": 1},
        "role_definitions": {"type": "object", "propertyNames": code,
            "additionalProperties": obj({"title": title, "description": text, "public_description": {**text, "maxLength": 500}}, ["title", "description"])},
        "clues": {"type": "object", "minProperties": 1, "maxProperties": 50, "propertyNames": code,
            "additionalProperties": obj({"title": title, "text": text, "shareable": {"type": "boolean"}})},
        "option_labels": {"type": "object", "propertyNames": code, "additionalProperties": title},
        "hints": {"type": "object", "propertyNames": code, "additionalProperties": obj({
            "exploration": arr(text, 2, 2), "decision": arr(text, 2, 2)}, [])},
    }
    required = ["schema_version", "story_id", "title", "seat_count", "roles", "phases",
                "variables", "actions", "decision", "timing", "media", "assets", "asset_status", "demo_only"]
    return {"$schema": "https://json-schema.org/draft/2020-12/schema",
            "title": "Ruxi C1 frozen content graph", "$defs": {"condition": condition}, **obj(props, required)}
