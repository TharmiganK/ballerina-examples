import ballerinax/health.hl7v28;

isolated function transformToPatient(hl7v28:ORU_R01 oruR01) returns Patient {
    Patient patient = {};
    patient.servicingfacility = oruR01.msh.msh6.hd1;
    hl7v28:ORU_R01_PATIENT? oruR01patient = oruR01.patient_result[0].oru_r01_patient;
    if oruR01patient is () {
        return patient;
    }
    patient.pid = oruR01patient.pid.pid3[0].cx1;
    patient.firstname = oruR01patient.pid.pid5[0].xpn2;
    patient.lastname = oruR01patient.pid.pid5[0].xpn1.fn1;
    patient.gender = oruR01patient.pid.pid8.cwe1;
    patient.address = oruR01patient.pid.pid11[0].xad1.sad1;
    patient.city = oruR01patient.pid.pid11[0].xad3;
    patient.state = oruR01patient.pid.pid11[0].xad4;
    patient.zip = oruR01patient.pid.pid11[0].xad5;
    patient.ssn = oruR01patient.pid.pid19;
    patient.phone = oruR01patient.pid.pid13[0].xtn2;
    patient.birthdate = oruR01patient.pid.pid7;

    hl7v28:ORU_R01_VISIT? oruR01visit = oruR01patient.oru_r01_visit;
    if oruR01visit is () {
        return patient;
    }
    patient.attendingdoctor = oruR01visit.pv1.pv17[0].xcn1 + " " + oruR01visit.pv1.pv17[0].xcn2.fn1 + " " + oruR01visit.pv1.pv17[0].xcn3 + " " + oruR01visit.pv1.pv17[0].xcn4;
    patient.admissiontype = oruR01visit.pv1.pv12.cwe1;
    patient.admitsource = oruR01visit.pv1.pv114.cwe1;
    patient.hospitalservice = oruR01visit.pv1.pv110.cwe1;

    patient.timeofvisit = oruR01.patient_result[0].oru_r01_order_observation[0].obr.obr7;
    hl7v28:ORU_R01_COMMON_ORDER? oruR01commonorder = oruR01.patient_result[0].oru_r01_order_observation[0].oru_r01_common_order;
    if oruR01commonorder is () || oruR01commonorder.orc is () {
        return patient;
    }
    hl7v28:ORC oruR01commonorderorc = <hl7v28:ORC>oruR01commonorder.orc;
    patient.referringdoctor = oruR01commonorderorc.orc10[0].xcn1 + " " + oruR01commonorderorc.orc10[0].xcn2.fn1 + " " + oruR01commonorderorc.orc10[0].xcn3 + " " + oruR01commonorderorc.orc10[0].xcn4;
    return patient;
}

isolated function buildObservation(hl7v28:ORU_R01_PATIENT_OBSERVATION patientObservation) returns Observation => {
    name: string `[${patientObservation.obx.obx3.cwe1}] ${patientObservation.obx.obx3.cwe2}`,
    'type: patientObservation.obx.obx2,
    value: patientObservation.obx.obx5.toString(),
    units: patientObservation.obx.obx6.cwe1,
    referencerange: patientObservation.obx.obx7,
    status: patientObservation.obx.obx11,
    timeofobservation: patientObservation.obx.obx14
};

isolated function createObservationMdReport(Patient patient, Observation observation) returns string =>
string `# Patient Report

## Patient Details

- **ID:** ${patient.pid}
- **Name:** ${patient.firstname} ${patient.lastname}
- **Gender:** ${patient.gender}
- **Address:** ${patient.address}, ${patient.city}, ${patient.state}, ${patient.zip}
- **SSN:** ${patient.ssn}
- **Phone:** ${patient.phone}
- **Birthdate:** ${patient.birthdate}
- **Attending Doctor:** ${patient.attendingdoctor}
- **Admission Type:** ${patient.admissiontype}
- **Admission Source:** ${patient.admitsource}
- **Hospital Service:** ${patient.hospitalservice}
- **Referring Doctor:** ${patient.referringdoctor}

## Observation Details

| Name | Type | Value | Units | Reference Range | Status | Time of Observation |
|------|------|-------|-------|------------------|--------|---------------------|
| ${observation.name} | ${observation.'type} | ${observation.value} | ${observation.units} | ${observation.referencerange} | ${observation.status} | ${observation.timeofobservation} |
`;

isolated function createObservationHtmlReport(Patient patient, Observation observation) returns string =>
string `<!DOCTYPE html>
<html>
<head>
    <title>Patient Report</title>
    <style>
        body { font-family: Arial, sans-serif; }
        table { width: 100%; border-collapse: collapse; }
        th, td { border: 1px solid #ddd; padding: 8px; }
        th { background-color: #f2f2f2; }
    </style>
</head>
<body>
    <h1>Patient Report</h1>
    <h2>Patient Details</h2>
    <ul>
        <li><strong>ID:</strong> ${patient.pid}</li>
        <li><strong>Name:</strong> ${patient.firstname} ${patient.lastname}</li>
        <li><strong>Gender:</strong> ${patient.gender}</li>
        <li><strong>Address:</strong> ${patient.address}, ${patient.city}, ${patient.state}, ${patient.zip}</li>
        <li><strong>SSN:</strong> ${patient.ssn}</li>
        <li><strong>Phone:</strong> ${patient.phone}</li>
        <li><strong>Birthdate:</strong> ${patient.birthdate}</li>
        <li><strong>Attending Doctor:</strong> ${patient.attendingdoctor}</li>
        <li><strong>Admission Type:</strong> ${patient.admissiontype}</li>
        <li><strong>Admission Source:</strong> ${patient.admitsource}</li>
        <li><strong>Hospital Service:</strong> ${patient.hospitalservice}</li>
        <li><strong>Referring Doctor:</strong> ${patient.referringdoctor}</li>
    </ul>
    <h2>Observation Details</h2>
    <table>
        <thead>
            <tr>
                <th>Name</th>
                <th>Type</th>
                <th>Value</th>
                <th>Units</th>
                <th>Reference Range</th>
                <th>Status</th>
                <th>Time of Observation</th>
            </tr>
        </thead>
        <tbody>
            <tr>
                <td>${observation.name}</td>
                <td>${observation.'type}</td>
                <td>${observation.value}</td>
                <td>${observation.units}</td>
                <td>${observation.referencerange}</td>
                <td>${observation.status}</td>
                <td>${observation.timeofobservation}</td>
            </tr>
        </tbody>
    </table>
</body>
</html>
`;
