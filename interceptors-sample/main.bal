import ballerina/http;

isolated table<User> key(id) users = table [
    {id: 1, name: "John Doe", email: "john.doe@gmail.com"},
    {id: 2, name: "Jane Doe", email: "jane.doe@gmail.com"}
];

listener http:Listener serverEP = new (9090,
    interceptors = [
        new DefaultResponseErrorInterceptor(),
        new DefaultResponseInterceptor(),
        new DefaultRequestInterceptor()
    ]
);

@http:ServiceConfig {
    interceptors: [new ServiceRequestInterceptor()]
}
service /users on serverEP {

    isolated resource function get .() returns User[] {
        lock {
            return users.cloneReadOnly().toArray();
        }
    }

    isolated resource function get [int id]() returns User|http:NotFoundError {
        lock {
            if users.hasKey(id) {
                return users.cloneReadOnly().get(id);
            }
        }
        return error http:NotFoundError("User not found", body = {
            "message": string `User with id ${id} not found`,
            "timestamp": getCurrentTimeStamp()
        });
    }

    isolated resource function post .(readonly & UserDetails user) returns http:Created {
        lock {
            // Limit the users for testing purposes
            if users.length() < 5 {
                users.add({id: users.length() + 1, ...user});
            }
            return http:CREATED;
        }
    }
}
