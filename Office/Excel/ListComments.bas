Sub ListComments()
    Dim wsc As Worksheet, ws As Worksheet, ct As CommentThreaded
    Dim strSheetName As String, strLink As String, strComment As String

    strSheetName = "Comments"
    Application.DisplayAlerts = False
    On Error Resume Next
    Worksheets(strSheetName).Delete
    Err.Clear
    Application.DisplayAlerts = True
    Set wsc = ThisWorkbook.Worksheets.Add(before:=Sheets(1))
    wsc.Name = "Comments"
    
    wsc.Cells(1, 1).Value = "Worksheet"
    wsc.Cells(1, 2).Value = "Cell"
    wsc.Cells(1, 3).Value = "Link"
    wsc.Cells(1, 4).Value = "Comments"
    
    For Each ws In ThisWorkbook.Worksheets
  ' Be sure to change worksheet names that need to be excluded
        If xWs.Name <> xTitleID And xWs.Name <> "Master Matrix" And xWs.Name <> "Dates" And xWs.Name <> "Report" Then
            For Each ct In ws.CommentsThreaded
                With wsc.Cells(Rows.Count, 1).End(xlUp).Offset(1)
                    .Value = ws.Name
                    .Offset(, 1).Value = ct.Parent.Address
                    strLink = ws.Name & "!" & ct.Parent.Address
                    .Offset(, 2).Hyperlinks.Add .Offset(, 2), "", strLink
                    strComment = ct.Author.Name & " (" & ct.Date & "):  " & ct.Text
                    For x = 1 To ct.Replies.Count
                        strComment = strComment & vbCrLf & r & ct.Replies(x).Author.Name & " (" & ct.Date & "):  " & ct.Replies(x).Text
                    Next x
                    .Offset(, 3).Value = strComment
                End With
            Next ct
        End If
    Next ws
    With wsc.Rows(1)
        .WrapText = True
        .Font.Bold = True
    End With
    With wsc.Columns("A:C")
        .ColumnWidth = 100
        .EntireColumn.AutoFit
    End With
    With wsc.Columns("D:D")
        .ColumnWidth = 100
        .WrapText = True
    End With
    
End Sub
