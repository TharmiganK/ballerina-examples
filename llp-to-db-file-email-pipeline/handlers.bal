import ballerina/log;
import ballerina/uuid;
import ballerina/io;
import ballerina/time;

import ballerinax/health.hl7v2;
import ballerinax/health.hl7v28;

import xlibb/pipeline;

@pipeline:TransformerConfig {
    id: "parseMllpHl7Message"
}
isolated function parseMllpHl7Message(pipeline:MessageContext ctx) returns hl7v2:Message|error => hl7v2:parse(check ctx.getContentWithType());

@pipeline:FilterConfig {
    id: "filterObservationMessage"
}
isolated function filterObservationMessage(pipeline:MessageContext ctx) returns boolean|error {
    hl7v2:Message message = check ctx.getContentWithType();
    if message.name == hl7v28:ORU_R01_MESSAGE_TYPE {
        return true;
    } else {
        log:printWarn(string `unsupported message type: ${message.name} found, expecting ORU_R01`);
        return false;
    }
}

@pipeline:TransformerConfig {
    id: "createReportFromMessage"
}
isolated function createReportFromMessage(pipeline:MessageContext ctx) returns Report|error {
    hl7v28:ORU_R01 message = check ctx.getContentWithType();
    Patient patient = transformToPatient(message);
    hl7v28:ORU_R01_PATIENT? oruR01patient = message.patient_result[0].oru_r01_patient;
    Observation observation = oruR01patient is () ? {} : buildObservation(oruR01patient.oru_r01_patient_observation[0]);
    return { patient, observation };
}

@pipeline:DestinationConfig {
    id: "writeReportToFile"
}
isolated function writeReportToFile(pipeline:MessageContext ctx) returns error? {
    Report report = check ctx.getContentWithType();
    string id = uuid:createType4AsString();
    string fileName = string `observations/report_${id}.md`;
    string reportContent = createObservationMdReport(report.patient, report.observation);
    return io:fileWriteString(fileName, reportContent);
}

@pipeline:DestinationConfig {
    id: "sendReportByEmail",
    retryConfig: {
        maxRetries: 3,
        retryInterval: 5
    }
}
isolated function sendReportByEmail(pipeline:MessageContext ctx) returns error? {
    Report report = check ctx.getContentWithType();
    string currentTimestamp = time:utcToEmailString(time:utcNow());
    string subject = string `[${currentTimestamp}] New Patient Report for patient id: ${report.patient.pid}`;
    string bodyInHtml = createObservationHtmlReport(report.patient, report.observation);
    _ = check gmailClient->/users/me/messages/send.post(
        {
            to: [adminEmail],
            subject,
            bodyInHtml
        }
    );
}

@pipeline:DestinationConfig {
    id: "insertPatientToDatabase"
}
isolated function insertPatientToDatabase(pipeline:MessageContext ctx) returns error? {
    Report report = check ctx.getContentWithType();
    Patient patient = report.patient;
    _ = check dbClient->execute(`INSERT INTO patient (pid, firstname, lastname, gender, address, city, state, zip, ssn, phone, birthdate, attendingdoctor, admissiontype, admitsource, hospitalservice, referringdoctor, servicingfacility, timeofvisit) 
                    VALUES (${patient.pid}, ${patient.firstname}, ${patient.lastname}, ${patient.gender}, ${patient.address}, ${patient.city}, ${patient.state}, ${patient.zip}, ${patient.ssn}, ${patient.phone}, ${patient.birthdate}, ${patient.attendingdoctor}, ${patient.admissiontype}, ${patient.admitsource}, ${patient.hospitalservice}, ${patient.referringdoctor}, ${patient.servicingfacility}, ${patient.timeofvisit})`);
}

@pipeline:DestinationConfig {
    id: "sendToHealthAnalyticsAPI",
    retryConfig: {
        maxRetries: 2,
        retryInterval: 3
    }
}
isolated function sendToHealthAnalyticsAPI(pipeline:MessageContext ctx) returns error? {
    Report report = check ctx.getContentWithType();
    anydata analyticsPayload = {
        patientId: report.patient.pid,
        timestamp: time:utcToEmailString(time:utcNow()),
        patient: {
            firstName: report.patient.firstname,
            lastName: report.patient.lastname,
            gender: report.patient.gender,
            city: report.patient.city,
            state: report.patient.state
        },
        observation: report.observation
    };
    return analyticsClient->/patient\-data.post(analyticsPayload);
}
