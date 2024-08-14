import ballerina/http;
import ballerina/http.httpscerr;

isolated table<User> key(id) users = table [
    {id: 1, name: "John Doe", email: "john.doe@gmail.com"},
    {id: 2, name: "Jane Doe", email: "jane.doe@gmail.com"}
];

listener http:Listener serverEP = new (9090);

service http:InterceptableService /users on serverEP {

    public function createInterceptors() returns http:Interceptor|http:Interceptor[] {
        return [
            new DefaultResponseErrorInterceptor(),
            new DefaultResponseInterceptor(),
            new DefaultRequestInterceptor(),
            new ServiceRequestInterceptor()
        ];
    }

    isolated resource function get .() returns User[] {
        lock {
            return users.cloneReadOnly().toArray();
        }
    }

    isolated resource function get [int id]() returns User|httpscerr:NotFoundError {
        lock {
            if users.hasKey(id) {
                return users.cloneReadOnly().get(id);
            }
        }
        return error httpscerr:NotFoundError("User not found", body = {
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
