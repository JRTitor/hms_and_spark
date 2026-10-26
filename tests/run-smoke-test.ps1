$ErrorActionPreference = 'Stop'

function Invoke-DockerCompose {
    param([string[]]$Arguments)

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # PowerShell can promote stderr from native programs (such as Java) to
        # terminating errors even when the program exits successfully.
        $ErrorActionPreference = 'Continue'
        $output = & docker compose @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    [pscustomobject]@{
        Output   = $output
        ExitCode = $exitCode
    }
}

Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    Write-Host 'Preparing an Iceberg table through Spark Thrift Server...'
    $prepare = Invoke-DockerCompose -Arguments @(
        'exec', '-T', 'spark', '/opt/spark/bin/beeline',
        '-u', 'jdbc:hive2://localhost:10000/default',
        '-n', 'smoke',
        '-f', '/tests/prepare-iceberg-smoke.sql'
    )
    $prepareOutput = $prepare.Output
    $prepareExitCode = $prepare.ExitCode
    $prepareText = $prepareOutput -join "`n"
    $prepareOutput | ForEach-Object { Write-Host $_ }
    if ($prepareExitCode -ne 0 -or
        $prepareText -notmatch 'SPARK_ICEBERG_PREPARE_OK' -or
        $prepareText -match '(?im)^\s*(Error:|FAILED:)') {
        throw 'The Spark prepare step failed. Check: docker compose logs spark metastore'
    }

    Write-Host 'Checking that Hive Metastore registered the Iceberg table in PostgreSQL...'
    $catalog = Invoke-DockerCompose -Arguments @(
        'exec', '-T', 'postgres', 'psql', '-U', 'hive', '-d', 'iceberg_metastore', '-At',
        '-f', '/tests/verify-iceberg-catalog.sql'
    )
    $catalogOutput = $catalog.Output
    $catalogExitCode = $catalog.ExitCode
    $catalogText = ($catalogOutput -join '').Trim()
    if ($catalogExitCode -ne 0 -or $catalogText -ne 't') {
        throw "Hive Metastore did not register the Iceberg smoke table in PostgreSQL. Output: $catalogText"
    }

    Write-Host 'Checking the table from a new Beeline session...'
    $verify = Invoke-DockerCompose -Arguments @(
        'exec', '-T', 'spark', '/opt/spark/bin/beeline',
        '-u', 'jdbc:hive2://localhost:10000/default',
        '-n', 'smoke',
        '-f', '/tests/verify-iceberg-smoke.sql'
    )
    $verifyOutput = $verify.Output
    $verifyExitCode = $verify.ExitCode
    $verifyText = $verifyOutput -join "`n"
    $verifyOutput | ForEach-Object { Write-Host $_ }
    if ($verifyExitCode -ne 0 -or
        $verifyText -notmatch 'SPARK_ICEBERG_VERIFY_OK' -or
        $verifyText -match '(?im)^\s*(Error:|FAILED:)') {
        throw 'The new-session verification failed. Check: docker compose logs spark metastore'
    }

    Write-Host 'Checking that Spark read an Iceberg data file from the S3 bucket...'
    if ($verifyText -notmatch 's3a://warehouse/spark-warehouse/spark_iceberg_smoke\.db/smoke_table/[^|\s]+\.parquet') {
        throw 'Spark did not read a Parquet data file from the Iceberg S3 warehouse.'
    }

    Write-Host ''
    Write-Host 'PASS: Iceberg registered its table in the remote Hive Metastore backed by PostgreSQL.'
    Write-Host 'PASS: a new Spark SQL session read the expected rows.'
    Write-Host 'PASS: Spark read Iceberg Parquet data from the S3-compatible warehouse.'
    Write-Host 'Run tests/cleanup-iceberg-smoke.sql with Beeline to remove the smoke-test namespace.'
}
finally {
    Pop-Location
}
