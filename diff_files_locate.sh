#!/bin/bash -x
# ###########################################################################
#       Name:           diff_files_locate.sh
#       Location:       /usr/local/dba/sh/
#       Function:       scan target directory and sync changed files to S3
#       Author:         Cheng Ran 
#       Create Date:    2018-03-30
#		Modify Date:	2018-04-28
#############################################################################

MAILLIST="#WW-NOC-DBA@xxx.com"

#check config file and initialize environment
CONFIG_FILE=/usr/local/dba/config/diff.cfg
if [ -s ${CONFIG_FILE} ]
then
    . ${CONFIG_FILE}
else
	mail -s "[Critical:] There is no configure file !"  $MAILLIST < /dev/null
    exit 1
fi

#check if exec varibles all provided
if [ $# -ge 1 ] ; then
    function=$1
else
     mail -s "[${ENV} Critical:] Please provide function parameter 1.init 2.diff !"  ${MAILLIST} < /dev/null
     exit 1
fi

#function is makeup
if [ "$function" == "makeup" ]
then
	rm -rf ${LOG_PATH}/total_files_1.log
	find "$SCAN_PATH" -print0 | xargs -0 du -ab | while read line;
	do
		lstr=`echo $line | awk '{print $1}'`
		length=${#lstr}
		substr=${line:$length}
		echo $substr > ${LOG_PATH}/proceeding_files.log
		cat ${LOG_PATH}/proceeding_files.log | while read a;
		do
		  cd "$a"
		  if [ $? -ne 0 ]
			then 
				echo $a >> ${LOG_PATH}/total_files_1.log
		  fi
		done
	done

	sync_flag=0
	diff_flag=0
	
	cat ${LOG_PATH}/total_files_1.log | while read line;
	do
		file_size_local=`du -sb "$line" | awk '{print $1}'`
#		a=${line:22}
		a=${line:32}
		b="${s3_title}/${a}"
		file_size_s3_o=`$aws_path s3 ls "$b" | sed '2,$d' | awk '{print $3}'`
		if [ "$file_size_s3_o"x == ""x -o "$file_size_s3_o"x == "0"x ]
		then
			file_size_s3=0
			sync_flag=1	
			diff_flag=0
		else
			file_size_s3=$file_size_s3_o

			if [ $file_size_local -gt $file_size_s3 ] && [ $file_size_s3 != 0 ]
			then 
				sync_flag=1
				diff_flag=0
			fi
			if [ $file_size_local -lt $file_size_s3 ] && [ $file_size_s3 != 0 ]
			then
				sync_flag=0
				diff_flag=1
			fi
			if [ $file_size_local -eq $file_size_s3 ] && [ $file_size_s3 != 0 ]
			then
				sync_flag=0
				diff_flag=0
			fi
		fi
		
#avoid single quotation mark in file name 
		dd=`date '+%Y-%m-%d %H:%M:%S'`
		echo "$line" > ${LOG_PATH}/filer_special_symbol_local.log
		sed -i "s/'/\\\\'\\\/g" ${LOG_PATH}/filer_special_symbol_local.log
		line=`cat ${LOG_PATH}/filer_special_symbol_local.log`
		
		echo "$b" > ${LOG_PATH}/filer_special_symbol_s3.log
		sed -i "s/'/\\\\'\\\/g" ${LOG_PATH}/filer_special_symbol_s3.log
		b=`cat ${LOG_PATH}/filer_special_symbol_s3.log`
		
		ssh -n ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"insert into $init_table(instance_id,instance_name,private_ips,region_id,instance_type,instance_owner,local_file,file_size_local,s3_file,file_size_s3,sync_flag,diff_flag,create_time) values('$instance_id','$instance_name','$private_ips','$region_id','$instance_type','$instance_owner','$line','$file_size_local','$b','$file_size_s3','$sync_flag','$diff_flag','$dd');\""
	done
	
#locate matched ids by filter
	d=`date '+%Y-%m-%d %H:%M:%S'`
	today=`expr substr "$d" 1 10`

	filter=`cat /usr/local/dba/config/target.cfg`

	rm -rf ${LOG_PATH}/matched_id_sync.result
	rm -rf ${LOG_PATH}/matched_id_diff.result
	for target in ${filter} 
	do
		cd1=`echo $target | awk -F':' '{print $1}'`
		cd2=`echo $target | awk -F':' '{print $2}'`
		ssh -n ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"select id from $init_table where sync_flag=1 and local_file like '%${cd1}%' and local_file like '%${cd2}%';\"" >> ${LOG_PATH}/matched_id_sync.result
		ssh -n ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"select id from $init_table where diff_flag=1 and local_file like '%${cd1}%' and local_file like '%${cd2}%';\"" >> ${LOG_PATH}/matched_id_diff.result
	done 
	
#sync to s3 and check upload result 
if [ -s ${LOG_PATH}/matched_id_sync.result ]
then 
	rm -rf ${LOG_PATH}/upload_to_s3.log
	ID=`cat ${LOG_PATH}/matched_id_sync.result`
	for ID1 in ${ID}
	do
		ssh -n ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"select concat(id,'*',local_file,'*',s3_file)from $init_table where id = $ID1;\"" | while read mysql; do
		echo ${mysql} >> ${LOG_PATH}/upload_to_s3.log
		done
	done

	cat ${LOG_PATH}/upload_to_s3.log | while read LINE
	do
		id=`echo $LINE | awk -F'*' '{print $1}'`
		local_file=`echo $LINE | awk -F'*' '{print $2}'`
		s3_file=`echo $LINE | awk -F'*' '{print $3}'`
		
		size1=`du -sb "$local_file" | awk '{print $1}'`
		$aws_path s3 cp "$local_file" "$s3_file"
		size2=`$aws_path s3 ls "$s3_file" | sed '2,$d' | awk '{print $3}'`
		if [ $size1 -ne $size2 ]
		then 
			upload_flag=2
			ssh -n ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"update $init_table set upload_flag=$upload_flag where id = $id;\""
		else 
			upload_flag=1
			ssh -n ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"update $init_table set upload_flag=$upload_flag where id = $id;\""
		fi
	done

	ssh ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"update $init_table set sync_flag=0;\""
#generate report by different file type
	rm -rf ${LOG_PATH}/report.log
	ssh -n ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"select concat(id,':',instance_id,':',instance_name,':',private_ips,':',region_id,':',instance_type,':',instance_owner,':',local_file,':',file_size_local) from $init_table where upload_flag=2;\"" | while read mysql; do
	echo ${mysql} >> ${LOG_PATH}/report.log
	done

	echo "<html>" > $HTMLFILE
	
if [ -s ${LOG_PATH}/report.log ]
then
	echo "<html>" > $HTMLFILE
	echo "<body><h3>Detail info of failed upload files on $instance_name:</h3>" > $HTMLFILE
	echo "<table border=\"1\" bordercolor=\"#000000\" width=\"1200\" cellpadding=\"10\" style=\"BORDER-COLLAPSE: collapse\" >" >> $HTMLFILE
	echo "<tr style=\"color:White\" bgColor=#0066CC><th>id</th><th>instance_id</th><th>instance_name</th><th>private_ips</th><th>region_id</th><th>instance_type</th><th>instance_owner</th><th>local_file</th><th>file_size_local</th></tr>" >> $HTMLFILE
	
	cat ${LOG_PATH}/report.log | while read LINE
	do
		id=`echo $LINE | awk -F':' '{print $1}'`
		instance_id=`echo $LINE | awk -F':' '{print $2}'`
		instance_name=`echo $LINE | awk -F':' '{print $3}'`
		private_ips=`echo $LINE | awk -F':' '{print $4}'`
		region_id=`echo $LINE | awk -F':' '{print $5}'`
		instance_type=`echo $LINE | awk -F':' '{print $6}'`
		instance_owner=`echo $LINE | awk -F':' '{print $7}'`
		local_file=`echo $LINE | awk -F':' '{print $8}'`
		file_size_local=`echo $LINE | awk -F':' '{print $9}'`
		echo "<tr align=\"center\" ><td>$id</td><td>$instance_id</td><td>$instance_name</td><td>$private_ips</td><td>$region_id</td><td>$instance_type</td><td>$instance_owner</td><td>$local_file</td><td>$file_size_local</td></tr>" >> $HTMLFILE
	done
else
	count=`ssh ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"select count(1) from $init_table where upload_flag=1;\""`
	echo "<body><h3>All matched $count files on $instance_name have been successfully uploaded to s3</h3>" >> $HTMLFILE
fi

fi	
	
if [ -s ${LOG_PATH}/matched_id_diff.result ]
then
	rm -rf ${LOG_PATH}/report.log
	ssh -n ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"select concat(id,':',instance_id,':',instance_name,':',private_ips,':',region_id,':',instance_type,':',instance_owner,':',local_file,':',file_size_local,':',file_size_s3) from $init_table where diff_flag=1;\"" | while read mysql; do
	echo ${mysql} >> ${LOG_PATH}/report.log
	done
	
	echo "<body><h3>Detail info of size decreased files on $instance_name:</h3>" >> $HTMLFILE
	echo "<table border=\"1\" bordercolor=\"#000000\" width=\"1200\" cellpadding=\"10\" style=\"BORDER-COLLAPSE: collapse\" >" >> $HTMLFILE
	echo "<tr style=\"color:White\" bgColor=#0066CC><th>id</th><th>instance_id</th><th>instance_name</th><th>private_ips</th><th>region_id</th><th>instance_type</th><th>instance_owner</th><th>local_file</th><th>file_size_local</th><th>file_size_s3</th></tr>" >> $HTMLFILE
	
	cat ${LOG_PATH}/report.log | while read LINE
	do
		id=`echo $LINE | awk -F':' '{print $1}'`
		instance_id=`echo $LINE | awk -F':' '{print $2}'`
		instance_name=`echo $LINE | awk -F':' '{print $3}'`
		private_ips=`echo $LINE | awk -F':' '{print $4}'`
		region_id=`echo $LINE | awk -F':' '{print $5}'`
		instance_type=`echo $LINE | awk -F':' '{print $6}'`
		instance_owner=`echo $LINE | awk -F':' '{print $7}'`
		local_file=`echo $LINE | awk -F':' '{print $8}'`
		file_size_local=`echo $LINE | awk -F':' '{print $9}'`
		file_size_s3=`echo $LINE | awk -F':' '{print $10}'`
		echo "<tr align=\"center\" ><td>$id</td><td>$instance_id</td><td>$instance_name</td><td>$private_ips</td><td>$region_id</td><td>$instance_type</td><td>$instance_owner</td><td>$local_file</td><td>$file_size_local</td><td>$file_size_s3</td></tr>" >> $HTMLFILE
	done
	echo "</table></body></html>" >> $HTMLFILE
	echo "<h3>Please consider if need replace s3 files with local files</h3>" >> $HTMLFILE
else 
	echo "<body><h3>No size decreased files on $instance_name</h3>" >> $HTMLFILE
fi
	
	echo "</table></body></html>" >> $HTMLFILE
	echo "<h4>generated by DBA team,$d</h4>" >> $HTMLFILE
	
	cat $HTMLFILE | mutt -s "Content Raw Data files Changed Info Report of $instance_name" -e  "set content_type=text/html" -c "xxx@xxx" $MAILLIST  -a $HTMLFILE
	
	rm -rf $HTMLFILE

	
fi

#function is init
if [ "$function" == "init" ] 
then
	rm -rf ${LOG_PATH}/files_current.log
	find $SCAN_PATH -print0 | xargs -0 du -ab > ${LOG_PATH}/files_before.log
fi

#function is diff
if [ "$function" == "diff" ] 
then
	A=${LOG_PATH}/files_before.log
	if [ -s $A ]
		then 
			B=${LOG_PATH}/files_current.log
			find $SCAN_PATH -print0 | xargs -0 du -ab > $B
	else
		mail -s "Please provide init as parameter to run this script first!"  ${MAILLIST} < /dev/null
		exit 1
	fi	

CURR_DATE=`date '+%Y-%m-%d %H:%M:%S'`
DIFF=$(diff $A $B -c)
if [ -s $DIFF ]
then 
	echo "Nothing is changed after compared with yesterday's files at $CURR_DATE." > ${LOG_PATH}/compare_result.log
	exit 0
else 
	rm -rf ${LOG_PATH}/added_files_process.log
	echo "$DIFF" | awk -F'--- ' '{print $1}' | grep .*+ | sort -k2n | uniq | sed '/^$/d' | while read line;
	do
		lstr=`echo "$line" | awk -F'--- ' '{print $1}' | grep .*+ | awk '{print $2}'`
		lengtho=${#lstr}
		length=`expr $lengtho + 2`
		substr=${line:$length}
		echo $substr >> ${LOG_PATH}/added_files_process.log
	done
	
	rm -rf ${LOG_PATH}/changed_files_process.log
	echo "$DIFF" | awk -F'--- ' '{print $1}' | grep .*! | sort -k2n | uniq | sed '/^$/d' | while read line;
	do
		lstr=`echo "$line" | awk -F'--- ' '{print $1}' | grep .*! | awk '{print $2}'`
		lengtho=${#lstr}
		length=`expr $lengtho + 2`
		substr=${line:$length}
		echo $substr >> ${LOG_PATH}/changed_files_process.log
	done
	
	rm -rf ${LOG_PATH}/deleted_files_process.log
	echo "$DIFF" | awk -F'--- ' '{print $1}' | grep .*- | sort -k2n | uniq | sed '/^$/d' | while read line;
	do
		lstr=`echo "$line" | awk -F'--- ' '{print $1}' | grep .*- | awk '{print $2}'`
		lengtho=${#lstr}
		length=`expr $lengtho + 2`
		substr=${line:$length}
		echo $substr >> ${LOG_PATH}/deleted_files_process.log
	done
	
	flag=`date '+%Y-%m-%d'`
	sed -i "/${flag}/d" ${LOG_PATH}/deleted_files_process.log
	flag=`date '+%Y-%m-%d' -d'-1 day'`
	sed -i "/${flag}/d" ${LOG_PATH}/deleted_files_process.log
	
	flag=`date '+%Y-%m-%d'`
	sed -i "/${flag}/d" ${LOG_PATH}/added_files_process.log
	flag=`date '+%Y-%m-%d' -d'-1 day'`
	sed -i "/${flag}/d" ${LOG_PATH}/added_files_process.log

	flag=`date '+%Y-%m-%d'`
	sed -i "/${flag}/d" ${LOG_PATH}/changed_files_process.log
	flag=`date '+%Y-%m-%d' -d'-1 day'`
	sed -i "/${flag}/d" ${LOG_PATH}/changed_files_process.log
	
#This kind of check has a bug when any of the directory itself is deleted, the check result will also be FILES since the detected object no longer exists 
	cat ${LOG_PATH}/changed_files_process.log | sort -k2n | uniq | while read a;
	do
		cd "$a"
		if [ $? -ne 0 ]
			then 
				echo $a >> ${LOG_PATH}/changed_files_loaction.log
		fi
	done
	
	cat ${LOG_PATH}/added_files_process.log | while read a;
	do
		cd "$a"
		if [ $? -ne 0 ]
			then 
				echo $a >> ${LOG_PATH}/added_files_loaction.log
		fi
	done
	
	cat ${LOG_PATH}/deleted_files_process.log | while read a;
	do
		cd "$a"
		if [ $? -ne 0 ]
			then 
				echo $a >> ${LOG_PATH}/deleted_files_loaction.log
		fi
	done
	
	cat ${LOG_PATH}/added_files_loaction.log | while read line 
	do
		#avoid single quotation mark in file name 
		echo "$line" > ${LOG_PATH}/filer_special_symbol.log
		sed -i "s/'/\\\\'\\\/g" ${LOG_PATH}/filer_special_symbol.log
		line=`cat ${LOG_PATH}/filer_special_symbol.log`
		
		ssh -n ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"insert into $check_table (instance_id,instance_name,private_ips,region_id,instance_type,instance_owner,diff_file,diff_type,create_time) values('$instance_id','$instance_name','$private_ips','$region_id','$instance_type','$instance_owner','$line','added',now());\""
		if [ $? -ne 0 ];then
			mail -s "[$ENV Critical:] Can't connect mysql monitor db for table $check_table on $monitor_server when inserting filename $line, please check!" $MAILLIST <  /dev/null
		fi
	done 
	
	
	cat ${LOG_PATH}/changed_files_loaction.log | while read line 
	do
		echo "$line" > ${LOG_PATH}/filer_special_symbol.log
		sed -i "s/'/\\\\'\\\/g" ${LOG_PATH}/filer_special_symbol.log
		line=`cat ${LOG_PATH}/filer_special_symbol.log`
		
		ssh -n ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"insert into $check_table (instance_id,instance_name,private_ips,region_id,instance_type,instance_owner,diff_file,diff_type,create_time) values('$instance_id','$instance_name','$private_ips','$region_id','$instance_type','$instance_owner','$line','changed',now());\""
		if [ $? -ne 0 ];then
			mail -s "[$ENV Critical:] Can't connect mysql monitor db for table $check_table on $monitor_server when inserting filename $line, please check!" $MAILLIST <  /dev/null
		fi
	done
	
	cat ${LOG_PATH}/deleted_files_loaction.log | while read line 
	do
		echo "$line" > ${LOG_PATH}/filer_special_symbol.log
		sed -i "s/'/\\\\'\\\/g" ${LOG_PATH}/filer_special_symbol.log
		line=`cat ${LOG_PATH}/filer_special_symbol.log`
	
		ssh -n ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"insert into $check_table (instance_id,instance_name,private_ips,region_id,instance_type,instance_owner,diff_file,diff_type,create_time) values('$instance_id','$instance_name','$private_ips','$region_id','$instance_type','$instance_owner','$line','deleted',now());\""
		if [ $? -ne 0 ];then
			mail -s "[$ENV Critical:] Can't connect mysql monitor db for table $check_table on $monitor_server when inserting filename $line, please check!" $MAILLIST <  /dev/null
		fi
	done
	
	rm -rf ${LOG_PATH}/changed_files_loaction.log
	rm -rf ${LOG_PATH}/added_files_loaction.log
	rm -rf ${LOG_PATH}/deleted_files_loaction.log
fi

cat $B > $A

#compare with the requirement paths to filter if the changed files are valid to update/report
#d=`date '+%Y-%m-%d %H:%M:%S'`
d=`ssh ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"select now();\""`
today=`expr substr "$d" 1 10`

filter=`cat /usr/local/dba/config/target.cfg`

rm -rf ${LOG_PATH}/matched_id.result
for target in ${filter} 
do
	cd1=`echo $target | awk -F':' '{print $1}'`
	cd2=`echo $target | awk -F':' '{print $2}'`
	ssh ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"select id from $check_table where diff_file like '%${cd1}%' and diff_file like '%${cd2}%' and ( create_time >= '${today} 00:00:00' and create_time <= '${today} 23:59:59');\"" >> ${LOG_PATH}/matched_id.result
done 

#upload to s3, check if files with changed tag size decreased
#generate repots by matched results
if [ -s ${LOG_PATH}/matched_id.result ]
then 
	rm -rf ${LOG_PATH}/report.log
	rm -rf ${LOG_PATH}/upload_to_s3_changed.log
	rm -rf ${LOG_PATH}/upload_to_s3_added.log
	ID=`cat ${LOG_PATH}/matched_id.result`
	for ID1 in ${ID}
	do
		ssh ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"select concat(id,':',instance_id,':',instance_name,':',private_ips,':',region_id,':',instance_type,':',instance_owner,':',diff_file,':',diff_type) from $check_table where id = $ID1;\"" | while read mysql; do
		echo ${mysql} >> ${LOG_PATH}/report.log
		done
		
		ssh ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"select concat(id,':',diff_file) from $check_table where id = $ID1 and diff_type = 'changed';\"" | while read mysql; do
		echo ${mysql} >> ${LOG_PATH}/upload_to_s3_changed.log
		done
		
		ssh ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"select concat(id,':',diff_file) from $check_table where id = $ID1 and diff_type = 'added';\"" | while read mysql; do
		echo ${mysql} >> ${LOG_PATH}/upload_to_s3_added.log
		done
	done
	
	if [ -s ${LOG_PATH}/upload_to_s3_changed.log ]
	then 
		cat ${LOG_PATH}/upload_to_s3_changed.log | while read LINE
		do
			id=`echo $LINE | awk -F':' '{print $1}'`
			diff_file=`echo $LINE | awk -F':' '{print $2}'`
		
		file_size_local=`du -sb "$diff_file" | awk '{print $1}'`
		
		a=${diff_file:32}
		b="${s3_title}/${a}"
		file_size_s3=`$aws_path s3 ls "$b" | sed '2,$d' | awk '{print $3}'`
		
		if [ $file_size_s3 -gt $file_size_local ]
		then 
			ssh -n ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"update $check_table set upload_flag=3 where id = $id;\"" 
		else 
			size1=`du -sb "$diff_file" | awk '{print $1}'`
			$aws_path s3 cp "$diff_file" "$b"
			size2=`$aws_path s3 ls "$b" | sed '2,$d' | awk '{print $3}'`
			if [ $? -ne 0 ];then
				upload_flag=2
				ssh -n ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"update $check_table set upload_flag=$upload_flag where id = $id;\""
			else
				if [ $size1 -ne $size2 ]
				then 
					upload_flag=2
					ssh -n ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"update $check_table set upload_flag=$upload_flag where id = $id;\""
				else 
					upload_flag=1
					ssh -n ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"update $check_table set upload_flag=$upload_flag where id = $id;\""
				fi
			fi
		fi	
		done
	fi
	
	if [ -s ${LOG_PATH}/upload_to_s3_added.log ]
	then
		cat ${LOG_PATH}/upload_to_s3_added.log | while read LINE
		do
			id=`echo $LINE | awk -F':' '{print $1}'`
			diff_file=`echo $LINE | awk -F':' '{print $2}'`
		
		a=${diff_file:32}
		b="${s3_title}/${a}"
		size1=`du -sb "$diff_file" | awk '{print $1}'`
		$aws_path s3 cp "$diff_file" "$b"
		size2=`$aws_path s3 ls "$b" | sed '2,$d' | awk '{print $3}'`
		if [ $? -ne 0 ];then
			upload_flag=2
			ssh -n ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"update $check_table set upload_flag=$upload_flag where id = $id;\""	
		else
			if [ $size1 -ne $size2 ]
			then 
				upload_flag=2
				ssh -n ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"update $check_table set upload_flag=$upload_flag where id = $id;\""
			else 
				upload_flag=1
				ssh -n ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"update $check_table set upload_flag=$upload_flag where id = $id;\""
			fi
		fi
		done
	fi
	
	rm -rf ${LOG_PATH}/decreased_files.log
	rm -rf ${LOG_PATH}/failed_files.log
	ssh ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"select concat(id,':',instance_id,':',instance_name,':',private_ips,':',region_id,':',instance_type,':',instance_owner,':',diff_file,':',diff_type) from $check_table where upload_flag = 3;\"" > ${LOG_PATH}/decreased_files.log
	ssh ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"select concat(id,':',instance_id,':',instance_name,':',private_ips,':',region_id,':',instance_type,':',instance_owner,':',diff_file,':',diff_type) from $check_table where upload_flag = 2;\"" > ${LOG_PATH}/failed_files.log
	
	echo "<html>" > $HTMLFILE
	echo "<body><h3>Detail info of matched changed files on $instance_name:</h3>" > $HTMLFILE
	echo "<table border=\"1\" bordercolor=\"#000000\" width=\"1200\" cellpadding=\"10\" style=\"BORDER-COLLAPSE: collapse\" >" >> $HTMLFILE
	echo "<tr style=\"color:White\" bgColor=#0066CC><th>id</th><th>instance_id</th><th>instance_name</th><th>private_ips</th><th>region_id</th><th>instance_type</th><th>instance_owner</th><th>diff_file</th><th>diff_type</th></tr>" >> $HTMLFILE
	
	#cat ${LOG_PATH}/report.log | sort -k2n | uniq | sed '/^$/d' | while read LINE
	cat ${LOG_PATH}/report.log | while read LINE
	do
		id=`echo $LINE | awk -F':' '{print $1}'`
		instance_id=`echo $LINE | awk -F':' '{print $2}'`
		instance_name=`echo $LINE | awk -F':' '{print $3}'`
		private_ips=`echo $LINE | awk -F':' '{print $4}'`
		region_id=`echo $LINE | awk -F':' '{print $5}'`
		instance_type=`echo $LINE | awk -F':' '{print $6}'`
		instance_owner=`echo $LINE | awk -F':' '{print $7}'`
		diff_file=`echo $LINE | awk -F':' '{print $8}'`
		diff_type=`echo $LINE | awk -F':' '{print $9}'`
		echo "<tr align=\"center\" ><td>$id</td><td>$instance_id</td><td>$instance_name</td><td>$private_ips</td><td>$region_id</td><td>$instance_type</td><td>$instance_owner</td><td>$diff_file</td><td>$diff_type</td></tr>" >> $HTMLFILE
	done
	
	if [ -s ${LOG_PATH}/decreased_files.log ]
	then 
		echo "</table></body></html>" >> $HTMLFILE
		echo "<body><h3>Detail info of size decreased files on $instance_name:</h3>" >> $HTMLFILE
		echo "<table border=\"1\" bordercolor=\"#000000\" width=\"1200\" cellpadding=\"10\" style=\"BORDER-COLLAPSE: collapse\" >" >> $HTMLFILE
		echo "<tr style=\"color:White\" bgColor=#0066CC><th>id</th><th>instance_id</th><th>instance_name</th><th>private_ips</th><th>region_id</th><th>instance_type</th><th>instance_owner</th><th>diff_file</th><th>diff_type</th></tr>" >> $HTMLFILE
		
		cat ${LOG_PATH}/decreased_files.log | while read LINE
		do
			id=`echo $LINE | awk -F':' '{print $1}'`
			instance_id=`echo $LINE | awk -F':' '{print $2}'`
			instance_name=`echo $LINE | awk -F':' '{print $3}'`
			private_ips=`echo $LINE | awk -F':' '{print $4}'`
			region_id=`echo $LINE | awk -F':' '{print $5}'`
			instance_type=`echo $LINE | awk -F':' '{print $6}'`
			instance_owner=`echo $LINE | awk -F':' '{print $7}'`
			diff_file=`echo $LINE | awk -F':' '{print $8}'`
			diff_type=`echo $LINE | awk -F':' '{print $9}'`
			echo "<tr align=\"center\" ><td>$id</td><td>$instance_id</td><td>$instance_name</td><td>$private_ips</td><td>$region_id</td><td>$instance_type</td><td>$instance_owner</td><td>$diff_file</td><td>$diff_type</td></tr>" >> $HTMLFILE
		done
		
		echo "</table></body></html>" >> $HTMLFILE
		echo "<body><h3>Please consider if need replace s3 files with local files</h3>" >> $HTMLFILE
	else
		echo "</table></body></html>" >> $HTMLFILE
		echo "<body><h3>No size decreased files on $instance_name</h3>" >> $HTMLFILE
	fi
	
	if [ -s ${LOG_PATH}/failed_files.log ]
	then 
		echo "</table></body></html>" >> $HTMLFILE
		echo "<body><h3>Detail info of failed upload to s3 files on $instance_name:</h3>" >> $HTMLFILE
		echo "<table border=\"1\" bordercolor=\"#000000\" width=\"1200\" cellpadding=\"10\" style=\"BORDER-COLLAPSE: collapse\" >" >> $HTMLFILE
		echo "<tr style=\"color:White\" bgColor=#0066CC><th>id</th><th>instance_id</th><th>instance_name</th><th>private_ips</th><th>region_id</th><th>instance_type</th><th>instance_owner</th><th>diff_file</th><th>diff_type</th></tr>" >> $HTMLFILE
		
		cat ${LOG_PATH}/failed_files.log | while read LINE
		do
			id=`echo $LINE | awk -F':' '{print $1}'`
			instance_id=`echo $LINE | awk -F':' '{print $2}'`
			instance_name=`echo $LINE | awk -F':' '{print $3}'`
			private_ips=`echo $LINE | awk -F':' '{print $4}'`
			region_id=`echo $LINE | awk -F':' '{print $5}'`
			instance_type=`echo $LINE | awk -F':' '{print $6}'`
			instance_owner=`echo $LINE | awk -F':' '{print $7}'`
			diff_file=`echo $LINE | awk -F':' '{print $8}'`
			diff_type=`echo $LINE | awk -F':' '{print $9}'`
			echo "<tr align=\"center\" ><td>$id</td><td>$instance_id</td><td>$instance_name</td><td>$private_ips</td><td>$region_id</td><td>$instance_type</td><td>$instance_owner</td><td>$diff_file</td><td>$diff_type</td></tr>" >> $HTMLFILE
		done
	else
		echo "</table></body></html>" >> $HTMLFILE
		count=`ssh ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"select count(1) from $check_table where upload_flag=1;\""`
		echo "<body><h3>All matched $count files on $instance_name have been successfully uploaded to s3</h3>" >> $HTMLFILE	
	fi
	
	
	echo "</table></body></html>" >> $HTMLFILE
	echo "<h4>generated by DBA team,$d</h4>" >> $HTMLFILE
	
	cat $HTMLFILE | mutt -s "Content Raw Data files Changed Info Report of $instance_name" -e  "set content_type=text/html" -c "xxx@xxx" $MAILLIST  -a $HTMLFILE
	
	fi	
fi
ssh ${monitor_server_user}@${monitor_server} "$db_conn -D $check_db -Ne \"update $check_table set upload_flag=0 ;\""


exit 0
	
