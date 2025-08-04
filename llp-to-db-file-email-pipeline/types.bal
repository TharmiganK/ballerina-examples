public const UNKNOWN = "unknown";

public type Patient record {
    string pid = UNKNOWN;
    string firstname = UNKNOWN;
    string lastname = UNKNOWN;
    string gender = UNKNOWN;
    string address = UNKNOWN;
    string city = UNKNOWN;
    string state = UNKNOWN;
    string zip = UNKNOWN;
    string ssn = UNKNOWN;
    string phone = UNKNOWN;
    string birthdate = UNKNOWN;
    string attendingdoctor = UNKNOWN;
    string admissiontype = UNKNOWN;
    string admitsource = UNKNOWN;
    string hospitalservice = UNKNOWN;
    string referringdoctor = UNKNOWN;
    string servicingfacility = UNKNOWN;
    string timeofvisit = UNKNOWN;
};

public type Observation record {
    string name = UNKNOWN;
    string 'type = UNKNOWN;
    string value = UNKNOWN;
    string units = UNKNOWN;
    string referencerange = UNKNOWN;
    string status = UNKNOWN;
    string timeofobservation = UNKNOWN;
};

public type Report record {
    Patient patient;
    Observation observation;
};
