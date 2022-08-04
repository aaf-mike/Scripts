# List all users and attributes
# Get-ADUser -filter * -Properties * | epcsv FILENAME.csv -NoTypeInformation

# To export for a KnowBe4 import
# import-module activedirectory
# Get-ADUser -filter * -Properties EmailAddress,GivenName,SN,TelephoneNumber,department,city,department | epcsv KnowBe4_$(Get-Date -f yyyy-MM-dd).csv -NoTypeInformation 