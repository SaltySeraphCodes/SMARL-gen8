class LeaderboardTable { // Leaderboard table, intakes session ID and will auto generate the proper leaderboard type based off of live data

    constructor(_config, _data) {
      this.config = {
        parentElement: _config.parentElement,
        session_id: _config.session_id,
       
      }
      this.temp_data = _data

      this.initVis();
    }
  
    get_leaderboard_data(){ // Calls database to get session data
      console.log("getting data",this.temp_data,this.data);
      // Grabs session data:
      // if session data == pracice or qualifying (1 or 2), request all session laps
      // Organize laps by best and descending (can do in clever sql query)
      // if mode == 3: request session_realtime data table by session ID
      // sort by position, 


      let sessionData = this.get_session_data()
      vis.sessionType = 1 //data.session_type from database pull
      if (vis.sessionType ==3){
        // db.get_realtime.data
      }else{
        //db.get_session_data
      }
        return this.temp_data

    }

    // Will receive realtime data from database

    initVis() {
      let vis = this;
      
      console.log("init",vis.data)
    
      vis.tableSection = d3.select(vis.config.parentElement)
  
      vis.updateVis(); //leave this empty for now...
      //vis.renderVis();
    }
  
  
   
   updateVis() { 
        let data = this.get_leaderboard_data()
        let vis = this;
        //console.log("vis",vis.data,vis.data.length)
        // Just rebuild the whole table here

        // Depending on session Type (qual, practice):
        // Instead of pulling realtime data, it will pull all session lap data,
        // It will find the best laps of all racers, and sort them from fastest to slowest
        // THen it will display pos, name, s1, s2, s3, Best Lap
        
        // if it is race, it will pull realtime leaderboard data from 

        vis.sessionTable = document.createElement("table");
        vis.sessionTable.classList.add("table","table-hover","table-sm");
        let sessionHead = document.createElement("thead");
        if (vis.sessionType == 3 ) {
          sessionHead.innerHTML = `
          <tr>
          <th scope="col">Pos</th>
          <th scope="col">Name</th>
          <th scope="col">Split</th>
          <th scope="col">Last</th>
          <th scope="col">Best</th>
          </tr>`
        } else{
          sessionHead.innerHTML = `
          <tr>
          <th scope="col">Pos</th>
          <th scope="col">Name</th>
          <th scope="col">S1</th>
          <th scope="col">S2</th>
          <th scope="col">S3</th>
          <th scope="col">Best Lap</th>
          </tr>`

        }
        
        vis.sessionTable.appendChild(sessionHead);
        // ad pos delta from start of race?
        let sessionBody = document.createElement("tbody");
        // meat of the table based on racer_Id
        for (let i = 0; i < vis.data.length; i ++) {
          let lap = vis.data[i];
          if (vis.sessionType == 3) { // if catchall or matching racer
              let lapRow = document.createElement("tr")
              lapRow.innerHTML = `
                  <th scope="row"> ${lap.pos} </th>
                  <td> ${lap.racer_name} </td>
                  <td> ${lap.split} </td>
                  <td> ${lap.last} </td>
                  <td> ${lap.best} </td>`
              sessionBody.appendChild(lapRow);
              //console.log("Adding",i,lapRow)
          }else { // lap based data
            let lapRow = document.createElement("tr")
            lapRow.innerHTML = `
                <th scope="row"> ${lap.pos} </th>
                <td> ${lap.racer_name} </td>
                <td> ${lap.s1} </td>
                <td> ${lap.s2} </td>
                <td> ${lap.s3} </td>
                <td> ${lap.best} </td>`
            sessionBody.appendChild(lapRow);
            //console.log("Adding",i,lapRow)
          }
        }
      vis.sessionTable.appendChild(sessionBody)  
      vis.renderVis();
   }
  

    renderVis() {
        let vis = this;
        vis.tableSection.append(function() {
            return vis.sessionTable;
        })

    }
  
  }