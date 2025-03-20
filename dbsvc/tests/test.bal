import ballerina/sql;
import ballerina/test;
import ballerina/log;

DbSerbvice dbService = check new ();

@test:BeforeSuite
function setup() returns error? {
    _ = check (dbService.db)->execute(`CREATE TABLE IF NOT EXISTS test (name VARCHAR(255), value VARCHAR(255))`);
    _ = check (dbService.db)->execute(`INSERT INTO test (name, value) VALUES ('test_name', 'test_value')`);
}

@test:Config {}
function testGetConfigDetail() returns error? {
    TbleConfig|sql:Error result = dbService.getConfigDetail();

    if result is TbleConfig {
        test:assertEquals(result.name, "test_name", "Name should match");
        test:assertEquals(result.value, "test_value", "Value should match");
    } else {
        log:printError("Result should be TbleConfig", result);
        test:assertFail("Result should be TbleConfig");
    }
}

@test:AfterSuite
function cleanup() returns error? {
    _ = check (dbService.db)->execute(`DROP TABLE test`);
}
