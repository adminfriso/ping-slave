while 1:
    try:
        com = raw_input("s/i,file,volume(,time)>")
        comWords = com.split(",")
    except Exception as e:
        print(e)
