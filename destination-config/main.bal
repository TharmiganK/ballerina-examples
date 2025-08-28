import ballerina/io;

public enum DestinationType {
    STDERR = "stderr",
    STDOUT = "stdout",
    FILE = "file"
};

public type StandardDestination record {|
    readonly STDERR|STDOUT 'type = STDERR;
|};

public enum FileOutputMode {
    TRUNCATE,
    APPEND
};

public type FileOutputDestination record {|
    readonly FILE 'type = FILE;
    string path;
    FileOutputMode mode = APPEND;
|};

public type OutputDestination StandardDestination|FileOutputDestination;

configurable readonly & OutputDestination[] destinations = ?;

public function main() {
    io:println("Output destinations configured:", destinations);
}
