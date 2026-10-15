// JSON helpers behind the JSON inspector: formatting keeps key order and never touches string contents.
#import "JSONInspector.h"
#import <assert.h>

int main(void) {
    @autoreleasepool {
        NSString *src = @"{\"zeta\":1,\"alpha\":{\"b\":[1,2,{\"c\":null}],\"a\":\"x, {y}: [z] \\\"q\\\"\"},\"empty\":{},\"list\":[],\"t\":true}";

        NSString *pretty = JSONPretty(src);
        assert([pretty hasPrefix:@"{\n  \"zeta\": 1,\n  \"alpha\": {\n    \"b\": [\n      1,"]);
        assert([pretty containsString:@"\"a\": \"x, {y}: [z] \\\"q\\\"\""]); // string untouched
        assert([pretty containsString:@"\"empty\": {},\n  \"list\": [],"]);  // empty containers stay on one line
        assert([JSONMinify(pretty) isEqual:src]);                          // round trip, key order kept

        assert(JSONIsValid(src) && JSONIsValid(@"  [1, 2]  ") && !JSONIsValid(@"{\"a\": }") && !JSONIsValid(@"42") && !JSONIsValid(nil));
        assert(!JSONIsValid(@"hello") && !JSONIsValid(NSNull.null));

        JSONNode *root = JSONParse(src);
        assert([root.kind isEqual:@"object"] && root.children.count == 5);
        assert([root.children[0].key isEqual:@"zeta"] && [root.children[1].key isEqual:@"alpha"]); // order
        JSONNode *alpha = root.children[1];
        assert([alpha.children[0].kind isEqual:@"array"] && alpha.children[0].children.count == 3);
        assert([alpha.children[0].children[2].children[0].kind isEqual:@"null"]);
        assert([alpha.children[1].kind isEqual:@"string"] && [alpha.children[1].text isEqual:@"x, {y}: [z] \"q\""]);
        assert([root.children[4].kind isEqual:@"bool"] && [root.children[4].text isEqual:@"true"]);
        assert(!JSONParse(@"{\"a\": }"));

        puts("json_test: OK");
    }
    return 0;
}
