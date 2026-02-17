# openelis-isante-distro

Spin up the OpenELIS and OpenHIM services 

```
docker-compose up -d
```

Acces the services at 

| Instance  |     URL       | credentials (user : password)|
|---------- |:-------------:|------:                       |
| OpenELIS3 | https://localhost/ |    admin : adminADMIN!| 
| OpenHIM   |    http://localhost:9000/  |  root@openhim.org : openhim |


## Instructions 

1. Ensure IsatePLUS is running. 
1. Add/Upgrade the following [modules](./configs/isanteplus/custom_modules/) in IsantePLUS server
1. Ensure these Global properties are rightly set in IsatePlus as below

    ### LabOnFHIR Global Properties

    #### Integration / LIS Connectivity

    | Property | Description | Default Value |
    |---------|-------------|---------------|
    | `labonfhir.lisUrl` | The URL for an LIS system like OpenELIS system to communicate with | `http://localhost:5001/fhir/` |
    | `labonfhir.lisUserUuid` | UUID for the service user that represents a LIS like OpenELIS | `f9badd80-ab76-11e2-9e96-0800200c9a66` |
    | `labonfhir.activateFhirPush` | Switches on/off the FHIR Push Functionality within the module to an external LIS | `true` |
    | `labonfhir.authType` | HTTP Auth Type (Basic / SSL) | `Basic` |
    | `labonfhir.userName` | User name for HTTP Basic Auth with the LIS | `IsantePLUS` |
    | `labonfhir.password` | Password for HTTP Basic Auth with the LIS | `admin` |

    ---

    #### SSL Configuration (In case SSL AuthType is used)

    | Property | Description | Default Value |
    |---------|-------------|---------------|
    | `labonfhir.keystorePath` | Path to keystore for HttpClient | `/ssl/lf.keystore` |
    | `labonfhir.keystorePass` | Keystore password | `testtest` |
    | `labonfhir.truststorePath` | Path to truststore for HttpClient | `/ssl/lf.truststore` |
    | `labonfhir.truststorePass` | Truststore password | `testtest` |

    ---

    #### Patient & Identifier Configuration

    | Property | Description | Default Value |
    |---------|-------------|---------------|
    | `labonfhir.openmrsPatientIdentifier.uuid` | Patient Identifier used to generate the FHIR Identifier System | `05a29f94-c0ed-11e2-94be-8c13b969e334` |
    | `labonfhir.lisIdentifierSystem.url` | LIS Identifier System URL | `http://openelis-global.org/pat_nationalId` |

    ---

    #### Order & Workflow Configuration

    | Property | Description | Default Value |
    |---------|-------------|---------------|
    | `labonfhir.orderTestUuids` | Concept UUIDs to filter by for Test Orders that get sent to the LIS | `160046AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA,165254AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA` |
    | `labonfhir.labUpdateTriggerObject` | The OpenMRS object type that should trigger LIS synchronization — Encounter or Order | `Encounter` |
    | `labonfhir.addObsAsTaskInput` | Allows adding Obs as Task Input | `false` |
    | `labonfhir.filterOrderBytestUuids` | Allows filtering Orders by Test UUIDs | `false` |

    ---

    #### Compatibility

    | Property | Description | Default Value |
    |---------|-------------|---------------|
    | `labonfhir.openElisUrl` | OpenELIS URL for iSantePlus Lab Form compatibility | `http://localhost:5001/fhir/` |


1. Ensure Add the Right Test Catalogue ie tests with `Loinc Codes` ie add more tests to the [test config](./configs/openelis/configuration/backend/tests/isante-tests.csv)

1. To send an Order from IsantePlus to OpenELIS , Go to the Patient Dashboard , Open the Laboratory form , select `OpenELIS` as the destination , select tests and send.

1. The Electronic Orders should be accesed in OpenELIS via Electronic Orders

1. Ensure Results entry and Results Validation in OpenELIS

1. To Fetch back the Test Results from OpenELIS , Start the OpenELIS Pull Task in Isanteplus to pull back the results.

Note that All Transactions are Logged through OpenHIM


see [more](https://digi-uw.github.io/healthinformationexchange/lis-workflows/lis-workflows.html#tutorial-lab-order-communication-between-openmrs-and-openelis) for the EMR-LIS communication