import ballerina/sql;
import ballerinax/postgresql;
import ballerinax/postgresql.driver as _;

configurable string host = "localhost";
configurable string username = "postgres";
configurable string pwd = "mysecretpassword";
configurable string dbname = "postgres";
configurable int port = 5432;

public type TbleConfig record {
    string name;
    string value;
};

public class DbSerbvice {
    postgresql:Client db;

    public function init() returns sql:Error? {
        self.db = check new (host, username, pwd, dbname, port);
    }

    public function getConfigDetail() returns TbleConfig|sql:Error {
        sql:ParameterizedQuery query = `SELECT * FROM test`;
        return self.db->queryRow(query);
    }
}
