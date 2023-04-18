import ballerina/constraint;

type ResponsePayload record {|
    json message;
    string timestamp;
|};

type User record {|
    readonly int id;
    *UserDetails;
|};

type UserDetails record {|
    @constraint:String {minLength: 3}
    string name;
    @constraint:String {pattern: re `([a-zA-Z0-9._%\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,6})*`}
    string email;
|};
